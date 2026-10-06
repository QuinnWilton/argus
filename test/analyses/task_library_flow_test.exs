defmodule Argus.Analyses.TaskLibraryFlowTest do
  @moduledoc """
  Every library call `Argus.Extractors.TermFlow.Library` models carries a
  task's handle where the call says it goes: each catalogue entry below
  starts a task, puts it in a container, passes the container through
  the call, and either collects what the call answers or drops it. The
  collected variant is quiet only if value flow followed the handle
  through the call (a lost handle is reported never awaited); the
  dropped variant is reported only if the call is no escape (an escape
  is never reported). Every modeled call has an entry
  (`every modeled call has a catalogue entry`), and a property chains
  entries.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :souffle
  @moduletag timeout: 600_000

  alias Argus.Extractors.TermFlow.Library
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  # Generated code calls deprecated and odd functions on purpose: its
  # compiler warnings are noise here.
  defp quietly_compile(source) do
    {paths, _warnings} = ExUnit.CaptureIO.with_io(:stderr, fn -> Memo.compile_beams(source) end)
    paths
  end

  # ── Container shapes ────────────────────────────────────────────────
  #
  # How a function builds each shape from its task `t` (and `x`, `k`
  # arguments the compiler cannot fold), and how it collects every task a
  # term of the shape holds.

  @build %{
    task: "t",
    list: "[t]",
    lists: "[[t]]",
    map: "%{k => t}",
    keys: "%{t => x}",
    pairs: "[{k, t}]",
    kw: "[a: t]",
    tuple: "{t, x}",
    tuples: "[{t, x}]",
    set: "MapSet.new([t])"
  }

  defp collect(:task, v), do: "Task.await(#{v})"
  defp collect(:list, v), do: "Task.await_many(#{v})"
  defp collect(:lists, v), do: "Enum.each(#{v}, &Task.await_many/1)"
  defp collect(:map, v), do: "Enum.each(#{v}, fn {_key, t2} -> Task.await(t2) end)"
  defp collect(:keys, v), do: "Enum.each(#{v}, fn {t2, _value} -> Task.await(t2) end)"
  defp collect(:pairs, v), do: "Enum.each(#{v}, fn {_key, t2} -> Task.await(t2) end)"
  defp collect(:kw, v), do: collect(:pairs, v)
  defp collect(:tuple, v), do: "{t2, _} = #{v}\n    Task.await(t2)"
  defp collect(:tuples, v), do: "Enum.each(#{v}, fn {t2, _} -> Task.await(t2) end)"
  defp collect(:set, v), do: "Enum.each(#{v}, &Task.await/1)"
  defp collect(:pair, v), do: "{_key, t2} = #{v}\n    Task.await(t2)"
  defp collect(:map_of_lists, v), do: "Enum.each(#{v}, fn {_key, l2} -> Task.await_many(l2) end)"
  defp collect({:match, pattern, kind}, v), do: "#{pattern} = #{v}\n    " <> collect(kind, "c3")

  # ── The catalogue: {call, input shape, expression over `c`, output} ─
  #
  # An output of `:none` answers nothing of `c` (an inspection): the
  # collected variant collects `c` itself after the call.

  @catalogue [
    # Enum
    {{Enum, :reverse, 1}, :list, "Enum.reverse(c)", :list},
    {{Enum, :reverse, 2}, :list, "Enum.reverse(c, c)", :list},
    {{Enum, :reverse_slice, 3}, :list, "Enum.reverse_slice(c, 0, 1)", :list},
    {{Enum, :sort, 1}, :list, "Enum.sort(c)", :list},
    {{Enum, :sort, 2}, :list, "Enum.sort(c, :desc)", :list},
    {{Enum, :uniq, 1}, :list, "Enum.uniq(c)", :list},
    {{Enum, :dedup, 1}, :list, "Enum.dedup(c)", :list},
    {{Enum, :shuffle, 1}, :list, "Enum.shuffle(c)", :list},
    {{Enum, :take, 2}, :list, "Enum.take(c, 1)", :list},
    {{Enum, :drop, 2}, :list, "Enum.drop(c, 0)", :list},
    {{Enum, :take_every, 2}, :list, "Enum.take_every(c, 1)", :list},
    {{Enum, :drop_every, 2}, :list, "Enum.drop_every(c, 2)", :list},
    {{Enum, :take_random, 2}, :list, "Enum.take_random(c, 1)", :list},
    {{Enum, :slice, 2}, :list, "Enum.slice(c, 0..1)", :list},
    {{Enum, :slice, 3}, :list, "Enum.slice(c, 0, 1)", :list},
    {{Enum, :slide, 3}, :list, "Enum.slide(c, 0, 0)", :list},
    {{Enum, :concat, 1}, :list, "Enum.concat([c, c])", :list},
    {{Enum, :concat, 2}, :list, "Enum.concat(c, [])", :list},
    {{Enum, :to_list, 1}, :list, "Enum.to_list(c)", :list},
    {{Enum, :to_list, 1}, :map, "Enum.to_list(c)", :pairs},
    {{Enum, :into, 2}, :list, "Enum.into(c, [])", :list},
    {{Enum, :into, 2}, :pairs, "Enum.into(c, %{})", :map},
    {{Enum, :into, 2}, :list, "Enum.into(c, MapSet.new())", :list},
    {{Enum, :intersperse, 2}, :list, "Enum.intersperse(c, x)", :list},
    {{Enum, :split, 2}, :list, "Enum.split(c, 1)", {:match, "{c3, _}", :list}},
    {{Enum, :chunk_every, 2}, :list, "Enum.chunk_every(c, 1)", :lists},
    {{Enum, :chunk_every, 3}, :list, "Enum.chunk_every(c, 1, 1)", :lists},
    {{Enum, :chunk_every, 4}, :list, "Enum.chunk_every(c, 2, 2, [])", :lists},
    {{Enum, :zip, 1}, :list, "Enum.zip([c, c])", :tuples},
    {{Enum, :zip, 2}, :list, "Enum.zip(c, c)", :tuples},
    {{Enum, :unzip, 1}, :pairs, "Enum.unzip(c)", {:match, "{_, c3}", :list}},
    {{Enum, :with_index, 1}, :list, "Enum.with_index(c)", :tuples},
    {{Enum, :frequencies, 1}, :list, "Enum.frequencies(c)", :keys},
    {{Enum, :at, 2}, :list, "Enum.at(c, 0)", :task},
    {{Enum, :at, 3}, :list, "Enum.at(c, 0, x)", :task},
    {{Enum, :fetch!, 2}, :list, "Enum.fetch!(c, 0)", :task},
    {{Enum, :fetch, 2}, :list, "Enum.fetch(c, 0)", {:match, "{:ok, c3}", :task}},
    {{Enum, :random, 1}, :list, "Enum.random(c)", :task},
    {{Enum, :min, 1}, :list, "Enum.min(c)", :task},
    {{Enum, :max, 1}, :list, "Enum.max(c)", :task},
    {{Enum, :min, 2}, :list, "Enum.min(c, fn -> x end)", :task},
    {{Enum, :max, 2}, :list, "Enum.max(c, fn -> x end)", :task},
    {{Enum, :min, 3}, :list, "Enum.min(c, &<=/2, fn -> x end)", :task},
    {{Enum, :max, 3}, :list, "Enum.max(c, &>=/2, fn -> x end)", :task},
    {{Enum, :count, 1}, :list, "Enum.count(c)", :none},
    {{Enum, :empty?, 1}, :list, "Enum.empty?(c)", :none},
    {{Enum, :member?, 2}, :list, "Enum.member?(c, x)", :none},
    {{Enum, :sum, 1}, :list, "Enum.sum(c)", :none},
    {{Enum, :product, 1}, :list, "Enum.product(c)", :none},
    {{Enum, :join, 1}, :list, "Enum.join(c)", :none},
    {{Enum, :join, 2}, :list, "Enum.join(c, \",\")", :none},
    {{Enum, :each, 2}, :list, "Enum.each(c, fn t2 -> t2 end)", :none},
    {{Enum, :map, 2}, :list, "Enum.map(c, fn t2 -> t2 end)", :list},
    {{Enum, :map, 2}, :map, "Enum.map(c, fn {_k, t2} -> t2 end)", :list},
    {{Enum, :map, 2}, :keys, "Enum.map(c, fn {t2, _v} -> t2 end)", :list},
    {{Enum, :map, 2}, :list, "Enum.map(c, &List.wrap/1)", :lists},
    {{Enum, :flat_map, 2}, :list, "Enum.flat_map(c, fn t2 -> [t2] end)", :list},
    {{Enum, :filter, 2}, :list, "Enum.filter(c, fn _ -> true end)", :list},
    {{Enum, :reject, 2}, :list, "Enum.reject(c, fn _ -> false end)", :list},
    {{Enum, :take_while, 2}, :list, "Enum.take_while(c, fn _ -> true end)", :list},
    {{Enum, :drop_while, 2}, :list, "Enum.drop_while(c, fn _ -> false end)", :list},
    {{Enum, :uniq_by, 2}, :list, "Enum.uniq_by(c, & &1.ref)", :list},
    {{Enum, :dedup_by, 2}, :list, "Enum.dedup_by(c, & &1.ref)", :list},
    {{Enum, :sort_by, 2}, :list, "Enum.sort_by(c, & &1.ref)", :list},
    {{Enum, :sort_by, 3}, :list, "Enum.sort_by(c, & &1.ref, :desc)", :list},
    {{Enum, :chunk_by, 2}, :list, "Enum.chunk_by(c, & &1.ref)", :lists},
    {{Enum, :find, 2}, :list, "Enum.find(c, fn _ -> true end)", :task},
    {{Enum, :find, 3}, :list, "Enum.find(c, x, fn _ -> true end)", :task},
    {{Enum, :find_value, 2}, :list, "Enum.find_value(c, fn t2 -> t2 end)", :task},
    {{Enum, :find_value, 3}, :list, "Enum.find_value(c, x, fn t2 -> t2 end)", :task},
    {{Enum, :min_by, 2}, :list, "Enum.min_by(c, & &1.ref)", :task},
    {{Enum, :max_by, 2}, :list, "Enum.max_by(c, & &1.ref)", :task},
    {{Enum, :min_by, 3}, :list, "Enum.min_by(c, & &1.ref, &<=/2)", :task},
    {{Enum, :max_by, 3}, :list, "Enum.max_by(c, & &1.ref, &>=/2)", :task},
    {{Enum, :min_by, 4}, :list, "Enum.min_by(c, & &1.ref, &<=/2, fn -> x end)", :task},
    {{Enum, :max_by, 4}, :list, "Enum.max_by(c, & &1.ref, &>=/2, fn -> x end)", :task},
    {{Enum, :any?, 2}, :list, "Enum.any?(c, fn _ -> true end)", :none},
    {{Enum, :all?, 2}, :list, "Enum.all?(c, fn _ -> true end)", :none},
    {{Enum, :count, 2}, :list, "Enum.count(c, fn _ -> true end)", :none},
    {{Enum, :find_index, 2}, :list, "Enum.find_index(c, fn _ -> true end)", :none},
    {{Enum, :sum_by, 2}, :list, "Enum.sum_by(c, fn _ -> 1 end)", :none},
    {{Enum, :product_by, 2}, :list, "Enum.product_by(c, fn _ -> 1 end)", :none},
    {{Enum, :map_join, 2}, :list, "Enum.map_join(c, &inspect/1)", :none},
    {{Enum, :map_join, 3}, :list, "Enum.map_join(c, \",\", &inspect/1)", :none},
    {{Enum, :frequencies_by, 2}, :list, "Enum.frequencies_by(c, & &1)", :keys},
    {{Enum, :split_with, 2}, :list, "Enum.split_with(c, fn _ -> true end)",
     {:match, "{c3, _}", :list}},
    {{Enum, :split_while, 2}, :list, "Enum.split_while(c, fn _ -> true end)",
     {:match, "{c3, _}", :list}},
    {{Enum, :group_by, 2}, :list, "Enum.group_by(c, & &1.ref)", :map_of_lists},
    {{Enum, :group_by, 3}, :list, "Enum.group_by(c, & &1.ref, & &1)", :map_of_lists},
    {{Enum, :reduce, 2}, :list, "Enum.reduce(c, fn t2, _acc -> t2 end)", :task},
    {{Enum, :reduce, 3}, :list, "Enum.reduce(c, [], fn t2, acc -> [t2 | acc] end)", :list},
    {{Enum, :reduce_while, 3}, :list,
     "Enum.reduce_while(c, [], fn t2, acc -> {:cont, [t2 | acc]} end)", :list},
    {{Enum, :map_reduce, 3}, :list, "Enum.map_reduce(c, 0, fn t2, n -> {t2, n} end)",
     {:match, "{c3, _}", :list}},
    {{Enum, :map_reduce, 3}, :list, "Enum.map_reduce(c, [], fn t2, acc -> {1, [t2 | acc]} end)",
     {:match, "{_, c3}", :list}},
    {{Enum, :flat_map_reduce, 3}, :list, "Enum.flat_map_reduce(c, 0, fn t2, n -> {[t2], n} end)",
     {:match, "{c3, _}", :list}},
    {{Enum, :scan, 2}, :list, "Enum.scan(c, fn t2, _ -> t2 end)", :list},
    {{Enum, :scan, 3}, :list, "Enum.scan(c, x, fn t2, _ -> t2 end)", :list},
    {{Enum, :map_every, 3}, :list, "Enum.map_every(c, 2, & &1)", :list},
    {{Enum, :map_intersperse, 3}, :list, "Enum.map_intersperse(c, x, & &1)", :list},
    {{Enum, :with_index, 2}, :list, "Enum.with_index(c, fn t2, _i -> t2 end)", :list},
    {{Enum, :with_index, 2}, :list, "Enum.with_index(c, 1)", :tuples},
    {{Enum, :zip_with, 3}, :list, "Enum.zip_with(c, c, fn t2, _ -> t2 end)", :list},
    {{Enum, :into, 3}, :list, "Enum.into(c, [], & &1)", :list},
    {{Enum, :into, 3}, :list, "Enum.into(c, %{}, fn t2 -> {t2.ref, t2} end)", :map},
    # Stream: a stream is the list it would enumerate.
    {{Stream, :map, 2}, :list, "Stream.map(c, & &1)", :list},
    {{Stream, :flat_map, 2}, :list, "Stream.flat_map(c, &[&1])", :list},
    {{Stream, :filter, 2}, :list, "Stream.filter(c, fn _ -> true end)", :list},
    {{Stream, :reject, 2}, :list, "Stream.reject(c, fn _ -> false end)", :list},
    {{Stream, :each, 2}, :list, "Stream.each(c, & &1)", :list},
    {{Stream, :take_while, 2}, :list, "Stream.take_while(c, fn _ -> true end)", :list},
    {{Stream, :drop_while, 2}, :list, "Stream.drop_while(c, fn _ -> false end)", :list},
    {{Stream, :uniq_by, 2}, :list, "Stream.uniq_by(c, & &1.ref)", :list},
    {{Stream, :dedup_by, 2}, :list, "Stream.dedup_by(c, & &1.ref)", :list},
    {{Stream, :chunk_by, 2}, :list, "Stream.chunk_by(c, & &1.ref)", :lists},
    {{Stream, :map_every, 3}, :list, "Stream.map_every(c, 2, & &1)", :list},
    {{Stream, :scan, 2}, :list, "Stream.scan(c, fn t2, _ -> t2 end)", :list},
    {{Stream, :scan, 3}, :list, "Stream.scan(c, x, fn t2, _ -> t2 end)", :list},
    {{Stream, :zip_with, 3}, :list, "Stream.zip_with(c, c, fn t2, _ -> t2 end)", :list},
    {{Stream, :with_index, 2}, :list, "Stream.with_index(c, fn t2, _i -> t2 end)", :list},
    {{Stream, :with_index, 2}, :list, "Stream.with_index(c, 1)", :tuples},
    {{Stream, :with_index, 1}, :list, "Stream.with_index(c)", :tuples},
    {{Stream, :take, 2}, :list, "Stream.take(c, 1)", :list},
    {{Stream, :drop, 2}, :list, "Stream.drop(c, 0)", :list},
    {{Stream, :take_every, 2}, :list, "Stream.take_every(c, 1)", :list},
    {{Stream, :drop_every, 2}, :list, "Stream.drop_every(c, 2)", :list},
    {{Stream, :uniq, 1}, :list, "Stream.uniq(c)", :list},
    {{Stream, :dedup, 1}, :list, "Stream.dedup(c)", :list},
    {{Stream, :concat, 1}, :list, "Stream.concat([c, c])", :list},
    {{Stream, :concat, 2}, :list, "Stream.concat(c, [])", :list},
    {{Stream, :zip, 1}, :list, "Stream.zip([c, c])", :tuples},
    {{Stream, :zip, 2}, :list, "Stream.zip(c, c)", :tuples},
    {{Stream, :chunk_every, 2}, :list, "Stream.chunk_every(c, 1)", :lists},
    {{Stream, :chunk_every, 3}, :list, "Stream.chunk_every(c, 1, 1)", :lists},
    {{Stream, :chunk_every, 4}, :list, "Stream.chunk_every(c, 2, 2, [])", :lists},
    {{Stream, :intersperse, 2}, :list, "Stream.intersperse(c, x)", :list},
    {{Stream, :run, 1}, :list, "Stream.run(c)", :none},
    # List
    {{List, :first, 1}, :list, "List.first(c)", :task},
    {{List, :first, 2}, :list, "List.first(c, x)", :task},
    {{List, :last, 1}, :list, "List.last(c)", :task},
    {{List, :last, 2}, :list, "List.last(c, x)", :task},
    {{List, :flatten, 1}, :lists, "List.flatten(c)", :list},
    {{List, :flatten, 2}, :lists, "List.flatten(c, [])", :list},
    {{List, :wrap, 1}, :task, "List.wrap(c)", :list},
    {{List, :insert_at, 3}, :task, "List.insert_at([], 0, c)", :list},
    {{List, :replace_at, 3}, :task, "List.replace_at([x], 0, c)", :list},
    {{List, :update_at, 3}, :list, "List.update_at(c, 0, & &1)", :list},
    {{List, :delete, 2}, :list, "List.delete(c, x)", :list},
    {{List, :delete_at, 2}, :list, "List.delete_at(c, 5)", :list},
    {{List, :pop_at, 2}, :list, "List.pop_at(c, 0)", {:match, "{c3, _}", :task}},
    {{List, :pop_at, 3}, :list, "List.pop_at(c, 0, x)", {:match, "{c3, _}", :task}},
    {{List, :duplicate, 2}, :task, "List.duplicate(c, 2)", :list},
    {{List, :zip, 1}, :list, "List.zip([c, c])", :tuples},
    {{List, :keyfind, 3}, :pairs, "List.keyfind(c, k, 0)", :pair},
    {{List, :keyfind, 4}, :pairs, "List.keyfind(c, k, 0, {k, x})", :pair},
    {{List, :keyfind!, 3}, :pairs, "List.keyfind!(c, k, 0)", :pair},
    {{List, :keystore, 4}, :task, "List.keystore([], k, 0, {k, c})", :pairs},
    {{List, :keyreplace, 4}, :task, "List.keyreplace([{k, x}], k, 0, {k, c})", :pairs},
    {{List, :keydelete, 3}, :pairs, "List.keydelete(c, x, 0)", :pairs},
    {{List, :keytake, 3}, :pairs, "List.keytake(c, k, 0)", {:match, "{c3, _}", :pair}},
    {{List, :keysort, 2}, :pairs, "List.keysort(c, 0)", :pairs},
    {{List, :keysort, 3}, :pairs, "List.keysort(c, 0, :desc)", :pairs},
    {{List, :foldl, 3}, :list, "List.foldl(c, [], &[&1 | &2])", :list},
    {{List, :foldr, 3}, :list, "List.foldr(c, [], &[&1 | &2])", :list},
    {{List, :keymember?, 3}, :pairs, "List.keymember?(c, k, 0)", :none},
    {{List, :ascii_printable?, 1}, :list, "List.ascii_printable?(c)", :none},
    # Map
    {{Map, :values, 1}, :map, "Map.values(c)", :list},
    {{Map, :keys, 1}, :keys, "Map.keys(c)", :list},
    {{Map, :to_list, 1}, :map, "Map.to_list(c)", :pairs},
    {{Map, :new, 1}, :pairs, "Map.new(c)", :map},
    {{Map, :new, 2}, :list, "Map.new(c, fn t2 -> {t2.ref, t2} end)", :map},
    {{Map, :merge, 2}, :map, "Map.merge(c, %{})", :map},
    {{Map, :delete, 2}, :map, "Map.delete(c, :zz)", :map},
    {{Map, :drop, 2}, :map, "Map.drop(c, [:zz])", :map},
    {{Map, :take, 2}, :map, "Map.take(c, [k])", :map},
    {{Map, :from_struct, 1}, :map, "Map.from_struct(c)", :map},
    {{Map, :split, 2}, :map, "Map.split(c, [k])", {:match, "{c3, _}", :map}},
    {{Map, :intersect, 2}, :map, "Map.intersect(%{}, c)", :map},
    {{Map, :replace, 3}, :task, "Map.replace(%{a: x}, :a, c)", :map},
    {{Map, :replace!, 3}, :task, "Map.replace!(%{a: x}, :a, c)", :map},
    {{Map, :put_new, 3}, :task, "Map.put_new(%{}, :a, c)", :map},
    {{Map, :pop, 2}, :map, "Map.pop(c, k)", {:match, "{c3, _}", :task}},
    {{Map, :pop, 3}, :map, "Map.pop(c, k, x)", {:match, "{c3, _}", :task}},
    {{Map, :pop!, 2}, :map, "Map.pop!(c, k)", {:match, "{c3, _}", :task}},
    {{Map, :update, 4}, :map, "Map.update(c, k, x, & &1)", :map},
    {{Map, :update, 4}, :task, "Map.update(%{}, :a, c, & &1)", :map},
    {{Map, :update!, 3}, :map, "Map.update!(c, k, & &1)", :map},
    {{Map, :get_lazy, 3}, :map, "Map.get_lazy(c, k, fn -> x end)", :task},
    {{Map, :put_new_lazy, 3}, :task, "Map.put_new_lazy(%{}, :a, fn -> c end)", :map},
    {{Map, :filter, 2}, :map, "Map.filter(c, fn _ -> true end)", :map},
    {{Map, :reject, 2}, :map, "Map.reject(c, fn _ -> false end)", :map},
    {{Map, :has_key?, 2}, :map, "Map.has_key?(c, k)", :none},
    {{Map, :equal?, 2}, :map, "Map.equal?(c, %{})", :none},
    # Keyword
    {{Keyword, :get, 2}, :kw, "Keyword.get(c, :a)", :task},
    {{Keyword, :get, 3}, :kw, "Keyword.get(c, :a, x)", :task},
    {{Keyword, :fetch!, 2}, :kw, "Keyword.fetch!(c, :a)", :task},
    {{Keyword, :fetch, 2}, :kw, "Keyword.fetch(c, :a)", {:match, "{:ok, c3}", :task}},
    {{Keyword, :get_values, 2}, :kw, "Keyword.get_values(c, :a)", :list},
    {{Keyword, :values, 1}, :kw, "Keyword.values(c)", :list},
    {{Keyword, :keys, 1}, :kw, "Keyword.keys(c)", :none},
    {{Keyword, :put, 3}, :task, "Keyword.put([], :a, c)", :kw},
    {{Keyword, :put_new, 3}, :task, "Keyword.put_new([], :a, c)", :kw},
    {{Keyword, :merge, 2}, :kw, "Keyword.merge(c, [])", :kw},
    {{Keyword, :delete, 2}, :kw, "Keyword.delete(c, :zz)", :kw},
    {{Keyword, :take, 2}, :kw, "Keyword.take(c, [:a])", :kw},
    {{Keyword, :drop, 2}, :kw, "Keyword.drop(c, [:zz])", :kw},
    {{Keyword, :new, 1}, :kw, "Keyword.new(c)", :kw},
    {{Keyword, :to_list, 1}, :kw, "Keyword.to_list(c)", :kw},
    {{Keyword, :split, 2}, :kw, "Keyword.split(c, [:a])", {:match, "{c3, _}", :kw}},
    {{Keyword, :pop, 2}, :kw, "Keyword.pop(c, :a)", {:match, "{c3, _}", :task}},
    {{Keyword, :pop, 3}, :kw, "Keyword.pop(c, :a, x)", {:match, "{c3, _}", :task}},
    {{Keyword, :pop!, 2}, :kw, "Keyword.pop!(c, :a)", {:match, "{c3, _}", :task}},
    {{Keyword, :filter, 2}, :kw, "Keyword.filter(c, fn _ -> true end)", :kw},
    {{Keyword, :reject, 2}, :kw, "Keyword.reject(c, fn _ -> false end)", :kw},
    {{Keyword, :has_key?, 2}, :kw, "Keyword.has_key?(c, :a)", :none},
    {{Access, :get, 2}, :kw, "c[:a]", :task},
    {{Access, :get, 3}, :kw, "Access.get(c, :a, x)", :task},
    # MapSet: the list of its members.
    {{MapSet, :new, 1}, :list, "MapSet.new(c)", :set},
    {{MapSet, :new, 2}, :list, "MapSet.new(c, & &1)", :set},
    {{MapSet, :to_list, 1}, :set, "MapSet.to_list(c)", :list},
    {{MapSet, :put, 2}, :task, "MapSet.put(MapSet.new(), c)", :set},
    {{MapSet, :delete, 2}, :set, "MapSet.delete(c, x)", :set},
    {{MapSet, :union, 2}, :set, "MapSet.union(c, MapSet.new())", :set},
    {{MapSet, :difference, 2}, :set, "MapSet.difference(c, MapSet.new())", :set},
    {{MapSet, :intersection, 2}, :set, "MapSet.intersection(c, c)", :set},
    {{MapSet, :filter, 2}, :set, "MapSet.filter(c, fn _ -> true end)", :set},
    {{MapSet, :reject, 2}, :set, "MapSet.reject(c, fn _ -> false end)", :set},
    {{MapSet, :split_with, 2}, :set, "MapSet.split_with(c, fn _ -> true end)",
     {:match, "{c3, _}", :set}},
    {{MapSet, :member?, 2}, :set, "MapSet.member?(c, x)", :none},
    {{MapSet, :size, 1}, :set, "MapSet.size(c)", :none},
    # Tuples and the container BIFs called as functions.
    {{Tuple, :to_list, 1}, :tuple, "Tuple.to_list(c)", :list},
    {{:erlang, :tuple_to_list, 1}, :tuple, ":erlang.tuple_to_list(c)", :list},
    {{:erlang, :element, 2}, :tuple, "elem(c, 0)", :task},
    {{:erlang, :setelement, 3}, :task, "put_elem({x, x}, 0, c)", :tuple},
    {{:erlang, :++, 2}, :list, "c ++ [x]", :list},
    {{:erlang, :--, 2}, :list, "c -- [x]", :list},
    {{:erlang, :hd, 1}, :list, "hd(c)", :task},
    {{:erlang, :tl, 1}, :list, "tl(c ++ c)", :list},
    {{:erlang, :length, 1}, :list, "length(c)", :none},
    {{:erlang, :tuple_size, 1}, :tuple, "tuple_size(c)", :none},
    {{:erlang, :map_size, 1}, :map, "map_size(c)", :none},
    {{:erlang, :is_map_key, 2}, :map, "is_map_key(c, k)", :none},
    {{:erlang, :error, 1}, :list, "if(x == :never, do: :erlang.error({:bad, c}))", :none},
    {{:erlang, :error, 2}, :list, "if(x == :never, do: :erlang.error({:bad, c}, [x]))", :none},
    {{:erlang, :error, 3}, :list, "if(x == :never, do: :erlang.error({:bad, c}, [x], []))",
     :none},
    {{:erlang, :exit, 1}, :list, "if(x == :never, do: :erlang.exit({:bad, c}))", :none},
    {{:erlang, :raise, 3}, :list, "if(x == :never, do: :erlang.raise(:error, c, []))", :none},
    {{:erlang, :error, 1}, :map, "Map.merge(c, %{})", :map},
    {{Kernel, :inspect, 1}, :list, "inspect(c)", :none},
    {{Kernel, :inspect, 2}, :list, "inspect(c, limit: 1)", :none},
    {{IO, :inspect, 1}, :list, "IO.inspect(c)", :list},
    {{IO, :inspect, 2}, :list, "IO.inspect(c, label: \"c\")", :list},
    {{IO, :inspect, 3}, :list, "IO.inspect(:stdio, c, [])", :list},
    # :lists
    {{:lists, :reverse, 1}, :list, ":lists.reverse(c)", :list},
    {{:lists, :reverse, 2}, :list, ":lists.reverse(c, c)", :list},
    {{:lists, :append, 1}, :lists, ":lists.append(c)", :list},
    {{:lists, :append, 2}, :list, ":lists.append(c, [])", :list},
    {{:lists, :flatten, 1}, :lists, ":lists.flatten(c)", :list},
    {{:lists, :flatten, 2}, :lists, ":lists.flatten(c, [])", :list},
    {{:lists, :nth, 2}, :list, ":lists.nth(1, c)", :task},
    {{:lists, :nthtail, 2}, :list, ":lists.nthtail(0, c)", :list},
    {{:lists, :last, 1}, :list, ":lists.last(c)", :task},
    {{:lists, :droplast, 1}, :list, ":lists.droplast(c ++ c)", :list},
    {{:lists, :sublist, 2}, :list, ":lists.sublist(c, 1)", :list},
    {{:lists, :sublist, 3}, :list, ":lists.sublist(c, 1, 1)", :list},
    {{:lists, :delete, 2}, :list, ":lists.delete(x, c)", :list},
    {{:lists, :subtract, 2}, :list, ":lists.subtract(c, [])", :list},
    {{:lists, :sort, 1}, :list, ":lists.sort(c)", :list},
    {{:lists, :sort, 2}, :list, ":lists.sort(fn a, b -> a <= b end, c)", :list},
    {{:lists, :usort, 1}, :list, ":lists.usort(c)", :list},
    {{:lists, :usort, 2}, :list, ":lists.usort(fn a, b -> a <= b end, c)", :list},
    {{:lists, :keysort, 2}, :pairs, ":lists.keysort(1, c)", :pairs},
    {{:lists, :ukeysort, 2}, :pairs, ":lists.ukeysort(1, c)", :pairs},
    {{:lists, :keyfind, 3}, :pairs, ":lists.keyfind(k, 1, c)", :pair},
    {{:lists, :keystore, 4}, :task, ":lists.keystore(k, 1, [], {k, c})", :pairs},
    {{:lists, :keyreplace, 4}, :task, ":lists.keyreplace(k, 1, [{k, x}], {k, c})", :pairs},
    {{:lists, :keydelete, 3}, :pairs, ":lists.keydelete(x, 1, c)", :pairs},
    {{:lists, :keytake, 3}, :pairs, ":lists.keytake(k, 1, c)",
     {:match, "{:value, c3, _}", :pair}},
    {{:lists, :keymerge, 3}, :pairs, ":lists.keymerge(1, c, [])", :pairs},
    {{:lists, :merge, 2}, :list, ":lists.merge(c, [])", :list},
    {{:lists, :merge, 1}, :list, ":lists.merge([c])", :list},
    {{:lists, :zip, 2}, :list, ":lists.zip(c, c)", :tuples},
    {{:lists, :unzip, 1}, :pairs, ":lists.unzip(c)", {:match, "{_, c3}", :list}},
    {{:lists, :enumerate, 1}, :list, ":lists.enumerate(c)", :pairs},
    {{:lists, :enumerate, 2}, :list, ":lists.enumerate(1, c)", :pairs},
    {{:lists, :duplicate, 2}, :task, ":lists.duplicate(2, c)", :list},
    {{:lists, :split, 2}, :list, ":lists.split(1, c)", {:match, "{c3, _}", :list}},
    {{:lists, :uniq, 1}, :list, ":lists.uniq(c)", :list},
    {{:lists, :max, 1}, :list, ":lists.max(c)", :task},
    {{:lists, :min, 1}, :list, ":lists.min(c)", :task},
    {{:lists, :member, 2}, :list, ":lists.member(x, c)", :none},
    {{:lists, :keymember, 3}, :pairs, ":lists.keymember(k, 1, c)", :none},
    {{:lists, :sum, 1}, :list, ":lists.sum(c)", :none},
    {{:lists, :foreach, 2}, :list, ":lists.foreach(fn _ -> :ok end, c)", :none},
    {{:lists, :map, 2}, :list, ":lists.map(& &1, c)", :list},
    {{:lists, :flatmap, 2}, :list, ":lists.flatmap(&[&1], c)", :list},
    {{:lists, :filter, 2}, :list, ":lists.filter(fn _ -> true end, c)", :list},
    {{:lists, :takewhile, 2}, :list, ":lists.takewhile(fn _ -> true end, c)", :list},
    {{:lists, :dropwhile, 2}, :list, ":lists.dropwhile(fn _ -> false end, c)", :list},
    {{:lists, :uniq, 2}, :list, ":lists.uniq(& &1.ref, c)", :list},
    {{:lists, :partition, 2}, :list, ":lists.partition(fn _ -> true end, c)",
     {:match, "{c3, _}", :list}},
    {{:lists, :splitwith, 2}, :list, ":lists.splitwith(fn _ -> true end, c)",
     {:match, "{c3, _}", :list}},
    {{:lists, :any, 2}, :list, ":lists.any(fn _ -> true end, c)", :none},
    {{:lists, :all, 2}, :list, ":lists.all(fn _ -> true end, c)", :none},
    {{:lists, :search, 2}, :list, ":lists.search(fn _ -> true end, c)",
     {:match, "{:value, c3}", :task}},
    {{:lists, :filtermap, 2}, :list, ":lists.filtermap(fn t2 -> {true, t2} end, c)", :list},
    {{:lists, :foldl, 3}, :list, ":lists.foldl(&[&1 | &2], [], c)", :list},
    {{:lists, :foldr, 3}, :list, ":lists.foldr(&[&1 | &2], [], c)", :list},
    {{:lists, :mapfoldl, 3}, :list, ":lists.mapfoldl(fn t2, n -> {t2, n} end, 0, c)",
     {:match, "{c3, _}", :list}},
    {{:lists, :mapfoldr, 3}, :list, ":lists.mapfoldr(fn t2, n -> {t2, n} end, 0, c)",
     {:match, "{c3, _}", :list}},
    {{:lists, :zipwith, 3}, :list, ":lists.zipwith(fn a, _ -> a end, c, c)", :list},
    # :maps
    {{:maps, :values, 1}, :map, ":maps.values(c)", :list},
    {{:maps, :keys, 1}, :keys, ":maps.keys(c)", :list},
    {{:maps, :to_list, 1}, :map, ":maps.to_list(c)", :pairs},
    {{:maps, :from_list, 1}, :pairs, ":maps.from_list(c)", :map},
    {{:maps, :from_keys, 2}, :list, ":maps.from_keys(c, x)", :keys},
    {{:maps, :merge, 2}, :map, ":maps.merge(c, %{})", :map},
    {{:maps, :remove, 2}, :map, ":maps.remove(:zz, c)", :map},
    {{:maps, :without, 2}, :map, ":maps.without([:zz], c)", :map},
    {{:maps, :with, 2}, :map, ":maps.with([k], c)", :map},
    {{:maps, :intersect, 2}, :map, ":maps.intersect(%{}, c)", :map},
    {{:maps, :take, 2}, :map, ":maps.take(k, c)", {:match, "{c3, _}", :task}},
    {{:maps, :update, 3}, :task, ":maps.update(:a, c, %{a: x})", :map},
    {{:maps, :is_key, 2}, :map, ":maps.is_key(k, c)", :none},
    {{:maps, :size, 1}, :map, ":maps.size(c)", :none},
    {{:maps, :filter, 2}, :map, ":maps.filter(fn _, _ -> true end, c)", :map},
    {{:maps, :map, 2}, :map, ":maps.map(fn _, v -> v end, c)", :map},
    {{:maps, :fold, 3}, :map, ":maps.fold(fn _, v, acc -> [v | acc] end, [], c)", :list},
    {{:maps, :foreach, 2}, :map, ":maps.foreach(fn _, _ -> :ok end, c)", :none}
  ]

  # ── Generating the functions ────────────────────────────────────────

  defp collected_body({_mfa, from, expr, :none}),
    do: "_ = #{expr}\n    " <> collect(from, "c")

  defp collected_body({_mfa, _from, expr, to}), do: "c2 = #{expr}\n    " <> collect(to, "c2")

  defp dropped_body({_mfa, _from, expr, _to}), do: "_ = #{expr}\n    :ok"

  defp function_source(name, from, body) do
    """
      def #{name}(x, k) do
        _ = {x, k}
        t = Task.async(fn -> x end)
        c = #{Map.fetch!(@build, from)}
        #{body}
      end
    """
  end

  defp module_source(prefix, functions) do
    body =
      Enum.map_join(functions, "\n", fn {name, from, body} ->
        function_source(name, from, body)
      end)

    digest = :crypto.hash(:sha256, body) |> Base.encode16() |> binary_part(0, 12)
    "defmodule Argus.Test.Generated.#{prefix}#{digest} do\n#{body}\nend\n"
  end

  defp never_awaited(results) do
    results
    |> Rows.where(:mailbox, "task_result_defect", kind: "never_awaited", drop: [:kind])
    |> Enum.flat_map(fn [func | _] ->
      case Regex.run(~r/:-?(\w+)\/\d+/, func) do
        [_, name] -> [name]
        nil -> []
      end
    end)
    |> MapSet.new()
  end

  defp entry_name({{mod, fun, arity}, from, _expr, _to}, i),
    do: "#{inspect(mod)}.#{fun}/#{arity} from #{from} (entry #{i})"

  # ── Tests ───────────────────────────────────────────────────────────

  test "every modeled call has a catalogue entry" do
    covered = MapSet.new(@catalogue, &elem(&1, 0))
    missing = Library.models() |> Map.keys() |> Enum.reject(&MapSet.member?(covered, &1))
    assert missing == [], "modeled calls with no catalogue entry: #{inspect(Enum.sort(missing))}"
  end

  test "each catalogued call carries the task: collected is quiet, dropped is reported" do
    entries = Enum.with_index(@catalogue)

    functions =
      Enum.flat_map(entries, fn {{_mfa, from, _expr, _to} = entry, i} ->
        [
          {"collected_#{i}", from, collected_body(entry)},
          {"dropped_#{i}", from, dropped_body(entry)}
        ]
      end)

    paths = quietly_compile(module_source("Catalogue", functions))
    {:ok, results} = Memo.analyze(paths, :mailbox)
    reported = never_awaited(results)

    lost = for {e, i} <- entries, MapSet.member?(reported, "collected_#{i}"), do: entry_name(e, i)

    escaped =
      for {e, i} <- entries, not MapSet.member?(reported, "dropped_#{i}"), do: entry_name(e, i)

    assert lost == [], "value flow lost the task through:\n  " <> Enum.join(lost, "\n  ")

    assert escaped == [],
           "the call let the dropped task escape:\n  " <> Enum.join(escaped, "\n  ")
  end

  # ── Chains ──────────────────────────────────────────────────────────
  #
  # Entries whose input and output are both shapes a function can build
  # and collect chain: the output of one is the input of the next.

  @chainable for e = {_mfa, from, _expr, to} <- @catalogue,
                 Map.has_key?(@build, from) and is_atom(to) and to != :none and
                   (Map.has_key?(@build, to) or to == :map_of_lists),
                 do: e

  defp a_chain do
    gen all(
          start <- member_of(Enum.uniq(for {_, from, _, _} <- @chainable, do: from)),
          length <- integer(1..4),
          seeds <- list_of(integer(0..10_000), length: length),
          fate <- member_of([:collected, :dropped])
        ) do
      {steps, last} =
        Enum.map_reduce(seeds, start, fn seed, kind ->
          choices = for e = {_, ^kind, _, to} <- @chainable, to != :map_of_lists, do: e

          case choices do
            [] ->
              {nil, kind}

            _ ->
              step = Enum.at(choices, rem(seed, length(choices)))
              {step, elem(step, 3)}
          end
        end)

      %{start: start, steps: Enum.reject(steps, &is_nil/1), last: last, fate: fate}
    end
  end

  defp chain_body(%{steps: steps, last: last, fate: fate}) do
    {lines, var} =
      steps
      |> Enum.with_index()
      |> Enum.map_reduce("c", fn {{_mfa, _from, expr, _to}, i}, var ->
        next = "c_#{i}"
        {"#{next} = #{String.replace(expr, ~r/\bc\b/, var)}", next}
      end)

    tail = if fate == :collected, do: collect(last, var), else: "_ = #{var}\n    :ok"
    Enum.join(lines ++ [tail], "\n    ")
  end

  # A map holding the task under a literal key (`:a`), read later with
  # the unknown key `k`: the read follows only the map's unknown-key
  # field, so the task escapes there and is not reported, dropped or not.
  defp escapes_by_unknown_key?(%{steps: steps}) do
    steps
    |> Enum.drop_while(fn {_mfa, _from, expr, to} -> not (to == :map and expr =~ ~r/:a\b/) end)
    |> Enum.drop(1)
    |> Enum.any?(fn {_mfa, from, expr, _to} -> from == :map and expr =~ ~r/\bk\b/ end)
  end

  property "a chain of catalogued calls carries the task to what the chain does with it" do
    check all(chains <- list_of(a_chain(), min_length: 4, max_length: 12), max_runs: 8) do
      functions =
        for {chain, i} <- Enum.with_index(chains),
            do: {"chain_#{i}", chain.start, chain_body(chain)}

      source = module_source("Chain", functions)
      {:ok, results} = Memo.analyze(quietly_compile(source), :mailbox)
      reported = never_awaited(results)

      for {chain, i} <- Enum.with_index(chains) do
        reportable? = chain.fate == :dropped and not escapes_by_unknown_key?(chain)

        assert MapSet.member?(reported, "chain_#{i}") == reportable?,
               "chain_#{i} (#{chain.fate}) through " <>
                 Enum.map_join(chain.steps, ", ", fn {{m, f, a}, _, _, _} ->
                   "#{inspect(m)}.#{f}/#{a}"
                 end) <>
                 "\n" <> source
      end
    end
  end
end
