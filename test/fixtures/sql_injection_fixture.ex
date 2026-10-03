defmodule Argus.Test.Fixtures.SqlInjection do
  @moduledoc false
  @compile {:no_warn_undefined, [Postgrex, MyXQL, Ecto.Adapters.SQL, UnknownSqlTransform]}

  def identifier(conn, name), do: Postgrex.query(conn, ~s(SELECT * FROM "#{name}"), [])

  def escaped_identifier(conn, name),
    do: Postgrex.query(conn, "SELECT * FROM " <> quoted(name), [])

  def unknown_dialect(repo, name),
    do: Ecto.Adapters.SQL.query(repo, "SELECT * FROM " <> quoted(name), [])

  def mysql_quotes(conn, value),
    do: MyXQL.query(conn, "SELECT " <> quoted(value), [])

  def nested_comment(conn, text),
    do: Postgrex.query(conn, "SELECT 1 /* outer /* inner */ #{quoted(text)} */", [])

  def line_comment(conn, text),
    do: Postgrex.query(conn, "SELECT 1 -- #{quoted(text)}\n", [])

  def ambiguous_backslash(conn, text),
    do: Postgrex.query(conn, "SELECT 'prefix\\' || #{quoted(text)}", [])

  def wrong_replace(conn, name),
    do: Postgrex.query(conn, ~s(SELECT * FROM "#{String.replace(name, "'", "''")}"), [])

  def escaped_elsewhere(conn, name, other) do
    _unused = quoted(other)
    Postgrex.query(conn, ~s(SELECT * FROM "#{name}"), [])
  end

  def partial_escape(conn, name, enabled) do
    name = if enabled, do: String.replace(name, "\"", "\"\""), else: name
    Postgrex.query(conn, ~s(SELECT * FROM "#{name}"), [])
  end

  def unknown_escape_branch(conn, name, enabled) do
    name =
      if enabled,
        do: String.replace(name, "\"", "\"\""),
        else: UnknownSqlTransform.transform(name)

    Postgrex.query(conn, ~s(SELECT * FROM "#{name}"), [])
  end

  def first_quote_only(conn, name) do
    name = String.replace(name, "\"", "\"\"", global: false)
    Postgrex.query(conn, ~s(SELECT * FROM "#{name}"), [])
  end

  def escaped_then_changed(conn, name) do
    name = name |> String.replace("\"", "\"\"") |> String.replace("x", "\"")
    Postgrex.query(conn, ~s(SELECT * FROM "#{name}"), [])
  end

  def dollar(conn, name), do: Postgrex.query(conn, "DO $$BEGIN LISTEN #{quoted(name)}; END$$", [])

  def tagged_dollar(conn, name),
    do: Postgrex.query(conn, "DO $block$BEGIN LISTEN #{quoted(name)}; END$block$", [])

  def fresh_dollar(conn, name),
    do: Postgrex.query(conn, "DO #{fresh_block("BEGIN LISTEN #{quoted(name)}; END")}", [])

  def fresh_unsafe_identifier(conn, name),
    do: Postgrex.query(conn, "DO #{fresh_block(~s(BEGIN LISTEN "#{name}"; END))}", [])

  def fresh_wrong_body(conn, name, other),
    do: Postgrex.query(conn, "DO #{wrong_block("BEGIN LISTEN #{quoted(name)}; END", other)}", [])

  def truncated_delimiter(conn, name),
    do: Postgrex.query(conn, "DO #{truncated_block("BEGIN LISTEN #{quoted(name)}; END")}", [])

  def raw_integer_tag(conn, name),
    do: Postgrex.query(conn, "DO #{raw_tag_block("BEGIN LISTEN #{quoted(name)}; END")}", [])

  def callback_state(state) do
    statements = Enum.map_join(state.channels, "\n", &"LISTEN #{quoted(&1)};")
    {:query, "DO $$BEGIN #{statements} END$$", state}
  end

  def captured(conn, names, suffix) do
    sql = Enum.map_join(names, "", fn _name -> "SELECT '#{suffix}'" end)
    Postgrex.query(conn, sql, [])
  end

  def joined_separator(conn, separator) do
    sql = Enum.map_join([1, 2], separator, fn _ -> "SELECT 1" end)
    Postgrex.query(conn, sql, [])
  end

  def joined_identifiers(conn, names, separator) do
    sql = Enum.map_join(names, separator, &quoted/1)
    Postgrex.query(conn, "SELECT " <> sql, [])
  end

  def joined_unknown_mapper(conn, names, separator, mapper) do
    Postgrex.query(conn, Enum.map_join(names, separator, mapper), [])
  end

  def joined_literal_separator(conn, names) do
    Postgrex.query(conn, "SELECT " <> Enum.map_join(names, ", ", &quoted/1), [])
  end

  def joined_empty(conn, separator) do
    Postgrex.query(conn, Enum.map_join([], separator, fn _ -> "SELECT 1" end), [])
  end

  def joined_singleton(conn, separator) do
    Postgrex.query(conn, Enum.map_join([1], separator, fn _ -> "SELECT 1" end), [])
  end

  def joined_without_separator(conn, names) do
    Postgrex.query(conn, Enum.map_join(names, &quoted/1), [])
  end

  def bound(conn, value), do: Postgrex.query(conn, "SELECT * FROM t WHERE id = $1", [value])
  def literal(conn), do: Postgrex.query(conn, "SELECT 1", [])
  def dynamic(conn, sql), do: Postgrex.query(conn, sql, [])
  def comment(conn, text), do: Postgrex.query(conn, ["SELECT 1 /*", text, "*/"], [])
  def value(conn, text), do: Postgrex.query(conn, "SELECT '#{text}'", [])

  def constant_helper(conn, ignored), do: Postgrex.query(conn, fixed(ignored), [])
  defp fixed(_), do: "SELECT 1"
  defp quoted(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  defp fresh_block(body) do
    delimiter =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&"$query_tag_#{&1}$")
      |> Enum.find(&(not String.contains?(body, &1)))

    delimiter <> body <> delimiter
  end

  defp wrong_block(body, other) do
    delimiter =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&"$query_tag_#{&1}$")
      |> Enum.find(&(not String.contains?(other, &1)))

    delimiter <> body <> delimiter
  end

  defp truncated_block(body) do
    delimiter =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&"$query_tag_#{&1}$")
      |> Enum.find(&(not String.contains?(body, &1)))

    <<delimiter::binary-size(1), body::binary, delimiter::binary-size(1)>>
  end

  defp raw_tag_block(body) do
    delimiter =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(fn counter -> <<"$query_tag_", counter::8, "$">> end)
      |> Enum.find(&(not String.contains?(body, &1)))

    delimiter <> body <> delimiter
  end
end

defmodule Argus.Test.Fixtures.SqlRepoFactory do
  @moduledoc false

  defmacro __using__(mode) do
    query =
      case mode do
        mode when mode in [:constructs, :two_calls] ->
          quote context: Ecto.Adapters.SQL do
            "SELECT * FROM records WHERE name = '#{sql}'"
          end

        _ ->
          quote context: Ecto.Adapters.SQL do
            sql
          end
      end

    head =
      if mode == :mixed do
        quote context: Ecto.Adapters.SQL do
          :generated
        end
      else
        quote context: Ecto.Adapters.SQL do
          sql
        end
      end

    quote generated: true, context: Ecto.Adapters.SQL do
      @compile {:no_warn_undefined, [Ecto.Adapters.SQL]}

      unquote(
        if mode == :delegates do
          quote generated: true, context: Ecto.Adapters.SQL do
            def query(sql, params \\ [], opts \\ [])
            def query!(sql, params \\ [], opts \\ [])
          end
        end
      )

      def query(unquote(head), params, opts) do
        unquote(
          if mode == :two_calls do
            quote context: Ecto.Adapters.SQL do
              Ecto.Adapters.SQL.query(__MODULE__, sql, params, opts)
            end
          end
        )

        Ecto.Adapters.SQL.query(
          Process.get({__MODULE__, :dynamic_repo}, __MODULE__),
          unquote(if mode == :mixed, do: "SELECT 1", else: query),
          params,
          opts
        )
      end

      def query!(sql, params, opts) do
        Ecto.Adapters.SQL.query!(
          Process.get({__MODULE__, :dynamic_repo}, __MODULE__),
          unquote(query),
          params,
          opts
        )
      end
    end
  end
end

defmodule Argus.Test.Fixtures.SqlRepoGenerated do
  @moduledoc false
  use Argus.Test.Fixtures.SqlRepoFactory, :delegates
end

defmodule Argus.Test.Fixtures.SqlRepoConstructed do
  @moduledoc false
  use Argus.Test.Fixtures.SqlRepoFactory, :constructs
end

defmodule Argus.Test.Fixtures.SqlRepoMixed do
  @moduledoc false
  use Argus.Test.Fixtures.SqlRepoFactory, :mixed

  def query(sql, params, opts), do: Ecto.Adapters.SQL.query(__MODULE__, sql, params, opts)
end

defmodule Argus.Test.Fixtures.SqlRepoTwoCalls do
  @moduledoc false
  use Argus.Test.Fixtures.SqlRepoFactory, :two_calls
end

defmodule Argus.Test.Fixtures.SqlRepoApplication do
  @moduledoc false
  @compile {:no_warn_undefined, [Ecto.Adapters.SQL]}

  def query(sql, params, opts), do: Ecto.Adapters.SQL.query(__MODULE__, sql, params, opts)

  def direct(repo, value),
    do: Ecto.Adapters.SQL.query(repo, "SELECT * FROM records WHERE name = '#{value}'", [])

  def through_repo(value),
    do: Argus.Test.Fixtures.SqlRepoGenerated.query("SELECT '#{value}'", [], [])

  def through_default(value),
    do: Argus.Test.Fixtures.SqlRepoGenerated.query!("SELECT '#{value}'")

  def through_two_args(value),
    do: Argus.Test.Fixtures.SqlRepoGenerated.query("SELECT '#{value}'", [])

  def repo_bound(value),
    do: Argus.Test.Fixtures.SqlRepoGenerated.query!("SELECT $1", [value])

  def repo_literal, do: Argus.Test.Fixtures.SqlRepoGenerated.query!("SELECT 1")

  def unrelated_query(value), do: Argus.Test.Fixtures.NotSql.query("prefix: #{value}")
end

defmodule Argus.Test.Fixtures.NotSql do
  @moduledoc false
  def query(value), do: value
end

defmodule Argus.Test.Fixtures.SqlComments do
  @moduledoc false

  def unchecked(options), do: envelope(options)

  # Construction remains in each export, as in drivers returning deferred work.
  def validated(options) do
    validate(options)
    %{__struct__: Postgrex.Stream, options: Keyword.put_new(options, :max_rows, 10)}
  end

  def wrong_value(options, other) do
    validate(other)
    %{__struct__: Postgrex.Stream, options: options}
  end

  def after_use(options) do
    stream = %{__struct__: Postgrex.Stream, options: options}
    validate(options)
    stream
  end

  def one_branch(options, check?) do
    if check?, do: validate(options)
    %{__struct__: Postgrex.Stream, options: options}
  end

  def rescued_validation(options) do
    try do
      validate(options)
    rescue
      _ -> :ignored
    end

    %{__struct__: Postgrex.Stream, options: options}
  end

  def non_rejecting(options) do
    observe(options)
    %{__struct__: Postgrex.Stream, options: options}
  end

  def changed_comment(options, comment) do
    validate(options)
    %{__struct__: Postgrex.Stream, options: Keyword.put(options, :comment, comment)}
  end

  def wrong_field(options) do
    validate_other(options)
    %{__struct__: Postgrex.Stream, options: options}
  end

  def incomplete(options) do
    validate_incomplete(options)
    %{__struct__: Postgrex.Stream, options: options}
  end

  def added_comment(comment),
    do: %{__struct__: Postgrex.Stream, options: Keyword.put([], :comment, comment)}

  def removed_comment(options),
    do: %{__struct__: Postgrex.Stream, options: Keyword.delete(options, :comment)}

  defp envelope(options), do: %{__struct__: Postgrex.Stream, options: options}

  defp validate(options) do
    case Keyword.get(options, :comment) do
      nil ->
        true

      comment when is_binary(comment) ->
        if String.contains?(comment, [<<0>>, "*/"]), do: raise("invalid"), else: false
    end
  end

  defp validate_other(options) do
    case Keyword.get(options, :name) do
      nil ->
        true

      text when is_binary(text) ->
        if String.contains?(text, [<<0>>, "*/"]), do: raise("invalid"), else: false
    end
  end

  defp validate_incomplete(options) do
    case Keyword.get(options, :comment) do
      nil ->
        true

      text when is_binary(text) ->
        if String.contains?(text, "*/"), do: raise("invalid"), else: false
    end
  end

  defp observe(options) do
    case Keyword.get(options, :comment) do
      nil ->
        true

      text when is_binary(text) ->
        if String.contains?(text, [<<0>>, "*/"]), do: :invalid, else: false
    end
  end
end
