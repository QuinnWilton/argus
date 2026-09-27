defmodule Argus.Locate.Source.ErlangTest do
  @moduledoc """
  The source's last step in Erlang, on tokens: a guard is the `try`'s
  `catch`/`after` to its `end`, a receive runs to its `end`, a clause to
  its `;` or `.`, a function to its `.`; anything else fails closed.
  """

  use ExUnit.Case, async: true

  alias Argus.Locate.Source.Erlang

  @moduletag :tmp_dir

  @source ~S"""
  -module(shapes).
  -export([fetch/1, wait/0, info/2, guarded/1, handlers/1, outside/1, nested/1]).

  fetch(Url) ->
      try httpc:request(Url) of
          {ok, R} -> R
      catch
          error:Reason ->
              logger:error("failed: ~p", [Reason]),
              error
      end.

  wait() ->
      receive
          {done, V} -> V;
          timeout -> nil
      after 5000 ->
          timeout
      end.

  info(tick, State) ->
      schedule(),
      {noreply, State};
  info({data, D}, State) when is_list(D); is_binary(D) ->
      {noreply, State#{data => D}}.

  guarded(F) ->
      try
          F()
      after
          cleanup()
      end.

  handlers(F) ->
      try F() catch _:_ ->
          recover()
      end.

  outside(F) ->
      catch F().

  nested(F) ->
      try
          case F() of
              ok -> fun(X) -> X end;
              _ -> fun lists:reverse/1
          end
      catch
          throw:T -> T
      end.
  """

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "shapes.erl")
    File.write!(path, @source)
    %{path: path}
  end

  test "a call in a try's body is guarded by its catch, to the last line before end", %{
    path: path
  } do
    # try httpc:request(Url) of ... — the call shares the try's line.
    assert Erlang.guard_keyword(path, 5) == "catch"
    assert Erlang.block_end(path, 5, :guard) == 10

    # One line: try F() catch _:_ -> ...
    assert Erlang.guard_keyword(path, 35) == "catch"
    assert Erlang.block_end(path, 35, :guard) == 36
  end

  test "an after section guards like a catch", %{path: path} do
    assert Erlang.guard_keyword(path, 29) == "after"
    assert Erlang.block_end(path, 29, :guard) == 31
  end

  test "the guard of a body nested in a case, past the funs in it", %{path: path} do
    assert Erlang.guard_keyword(path, 44) == "catch"
    assert Erlang.block_end(path, 44, :guard) == 49
  end

  test "an anchor in the of clauses or the handlers is not guarded", %{path: path} do
    assert Erlang.guard_keyword(path, 6) == nil
    assert Erlang.guard_keyword(path, 9) == nil
    assert Erlang.block_end(path, 9, :guard) == nil
  end

  test "an old-style catch expression guards its line, under its own keyword", %{path: path} do
    assert Erlang.guard_keyword(path, 40) == "catch"
    assert Erlang.block_end(path, 40, :guard) == nil
    # A try's own catch is no old-style one: its handler is not guarded.
    assert Erlang.guard_keyword(path, 7) == nil
  end

  test "a receive runs to its end, after clause included", %{path: path} do
    assert Erlang.block_end(path, 14, :receive) == 18
    assert Erlang.block_end(path, 13, :receive) == nil
  end

  test "a clause runs to its ; and a function to its .", %{path: path} do
    assert Erlang.block_end(path, 21, :clause) == 23
    # The guard's `;` is in the head, before `->`.
    assert Erlang.block_end(path, 24, :clause) == 25
    assert Erlang.block_end(path, 21, :function) == 25
    # Not a function head.
    assert Erlang.block_end(path, 22, :clause) == nil
  end

  test "a fragment moves the line to its whole token", %{path: path} do
    assert Erlang.refine(path, 20, "State") == 21
    assert Erlang.refine(path, 20, "tat") == 20
    assert Erlang.refine(path, 20, nil) == 20
  end

  test "a file that does not scan or cannot be read keeps the bytecode's place", %{
    tmp_dir: dir
  } do
    broken = Path.join(dir, "broken.erl")
    File.write!(broken, "f() -> \"unterminated.\n")

    assert Erlang.block_end(broken, 1, :function) == nil
    assert Erlang.guard_keyword(Path.join(dir, "missing.erl"), 1) == nil
    assert Erlang.refine(Path.join(dir, "missing.erl"), 3, "x") == 3
  end

  test "a line a -file directive renumbered is found where it stands", %{tmp_dir: dir} do
    # What a Gleam build writes: each function after a -file naming its
    # .gleam source, numbered from there.
    path = Path.join(dir, "gen.erl")

    File.write!(path, """
    -module(gen).
    -export([a/0, b/0]).

    -file("src/gen.gleam", 40).
    a() ->
        ok.

    -file("src/gen.gleam", 10).
    b() ->
        spawn(fun() -> ok end),
        ok.
    """)

    # The compiler's own numbering, for the record.
    {:ok, :gen, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info])

    {:ok, {:gen, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(beam, [:abstract_code])

    assert [{41, :a}, {11, :b}] = for({:function, {l, _}, name, 0, _} <- forms, do: {l, name})

    assert Erlang.line(path, 41) == 5
    assert Erlang.line(path, 11) == 9
    assert Erlang.line(path, 12) == 10
    # A number no directive's run holds is kept.
    assert Erlang.line(path, 3) == 3
    # A file without directives is numbered as it stands.
    assert Erlang.line(Path.join(dir, "missing.erl"), 7) == 7
  end
end
