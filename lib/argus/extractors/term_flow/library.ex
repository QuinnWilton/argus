defmodule Argus.Extractors.TermFlow.Library do
  @moduledoc """
  What the standard library's collection calls answer, for value flow.

  `Argus.Extractors.TermFlow` follows a value through a library call only
  where this table says what the call answers in terms of its arguments;
  every other library call is an escape (`value_escape`): what it is
  handed goes where no summary says. The table covers the collection
  APIs a value is commonly carried through — `Enum`, `Stream`, `List`,
  `Map`, `Keyword`, `MapSet`, `Tuple`, `:lists`, `:maps` and the
  container BIFs `:erlang` exposes as calls — and the calls that only
  inspect a value (`Enum.count/1`, `Map.has_key?/2`, ...), which answer
  nothing from it and do not keep it.

  A model is a value spec for the answer, or, for a call running a fun
  on each element, `{:run, fun_position, params, answer, others}`: the
  fun's parameters receive `params` (value specs), `answer` may name the
  fun's answer as `:result`, and `others` lists further funs the call
  runs, as `{position, params}`, whose answers it uses some other way
  (`Enum.group_by/3`'s key fun answers the map's keys).

  Value specs describe terms in the abstract heap TermFlow keeps:

    * `{:arg, n}` — argument `n`;
    * `:result` — what the fun the call runs answers;
    * `{:elements, spec}` — the elements enumerating `spec` yields: a
      list's `[]`, a map's `{key, value}` pairs, a MapSet's members
      (modeled as a list);
    * `{:read, spec, sel}` — field `sel` of `spec` (`"{1}"`, `"**"` for
      any field of a tuple);
    * `{:list, spec}` — a new list whose elements are `spec`;
    * `{:cons, head, tail}` — a new list cell;
    * `{:tuple, [spec | nil], tag}` — a new tuple;
    * `{:map, keys, values}` — a new map;
    * `{:put, map, key_position, value}` — `map` with the field
      argument `key_position` names set to `value`;
    * `{:field, map, key_position}` — that field of `map`;
    * `{:entry, map, key_position}` — the same, or, for a key the call
      does not know, any field of `map`: what an update hands its fun,
      whose answer goes back into the map, so a value under a literal
      key does not escape there as it does from a read;
    * `{:index, tuple, index_position}` — the 1-based tuple element
      argument `index_position` names;
    * `{:setelement, index_position, tuple, value}`;
    * `{:into, elements, collectable_position}` — `elements` collected
      into the collectable argument names: a list, a map of pairs, or
      either when the argument is not a literal;
    * `{:union, [spec]}`; `:none`.

  A model may also be `{:fun_or, position, running, plain}`: `running`
  when the argument at `position` is a fun, `plain` otherwise
  (`Enum.with_index/2` takes a fun or an offset).

  A MapSet is a list of its members here: no program reads its fields.
  """

  @type spec ::
          {:arg, non_neg_integer()}
          | :result
          | {:elements, spec()}
          | {:read, spec(), String.t()}
          | {:list, spec()}
          | {:cons, spec(), spec()}
          | {:tuple, [spec() | nil], String.t()}
          | {:map, spec(), spec()}
          | {:put, spec(), non_neg_integer(), spec()}
          | {:field, spec(), non_neg_integer()}
          | {:entry, spec(), non_neg_integer()}
          | {:index, spec(), non_neg_integer()}
          | {:setelement, non_neg_integer(), spec(), spec()}
          | {:into, spec(), non_neg_integer()}
          | {:union, [spec()]}
          | :none

  @type run ::
          {:run, non_neg_integer(), [spec()], spec(), [{non_neg_integer(), [spec()]}]}

  @type model :: spec() | run() | {:fun_or, non_neg_integer(), run(), spec()}

  # Spec shorthands, kept to this module.
  defp a(n), do: {:arg, n}
  defp el(spec), do: {:elements, spec}
  defp el_(n), do: el(a(n))
  defp u(specs), do: {:union, specs}
  defp list(spec), do: {:list, spec}
  defp tup(specs, tag \\ ""), do: {:tuple, specs, tag}
  defp first(spec), do: {:read, spec, "{0}"}
  defp second(spec), do: {:read, spec, "{1}"}
  defp keys(n), do: first(el_(n))
  defp values(n), do: second(el_(n))
  defp from_pairs(spec), do: {:map, first(spec), second(spec)}
  defp run(fun, params, answer, others \\ []), do: {:run, fun, params, answer, others}

  # ── Enum ────────────────────────────────────────────────────────────

  defp enum do
    %{
      # Order, part or join of the enumerable.
      {Enum, :reverse, 1} => a(0),
      {Enum, :reverse, 2} => u([a(0), a(1)]),
      {Enum, :reverse_slice, 3} => a(0),
      {Enum, :sort, 1} => a(0),
      {Enum, :sort, 2} => a(0),
      {Enum, :uniq, 1} => a(0),
      {Enum, :dedup, 1} => a(0),
      {Enum, :shuffle, 1} => a(0),
      {Enum, :take, 2} => a(0),
      {Enum, :drop, 2} => a(0),
      {Enum, :take_every, 2} => a(0),
      {Enum, :drop_every, 2} => a(0),
      {Enum, :take_random, 2} => a(0),
      {Enum, :slice, 2} => a(0),
      {Enum, :slice, 3} => a(0),
      {Enum, :slide, 3} => a(0),
      {Enum, :concat, 1} => list(el(el_(0))),
      {Enum, :concat, 2} => u([a(0), a(1)]),
      {Enum, :to_list, 1} => list(el_(0)),
      {Enum, :into, 2} => {:into, el_(0), 1},
      {Enum, :intersperse, 2} => list(u([el_(0), a(1)])),
      {Enum, :split, 2} => tup([a(0), a(0)]),
      {Enum, :chunk_every, 2} => list(a(0)),
      {Enum, :chunk_every, 3} => list(a(0)),
      {Enum, :chunk_every, 4} => list(u([a(0), a(3)])),
      {Enum, :zip, 1} => list(tup([el(el_(0)), el(el_(0))])),
      {Enum, :zip, 2} => list(tup([el_(0), el_(1)])),
      {Enum, :unzip, 1} => tup([list(keys(0)), list(values(0))]),
      {Enum, :with_index, 1} => list(tup([el_(0), nil])),
      {Enum, :frequencies, 1} => {:map, el_(0), :none},
      # One element.
      {Enum, :at, 2} => el_(0),
      {Enum, :at, 3} => u([el_(0), a(2)]),
      {Enum, :fetch!, 2} => el_(0),
      {Enum, :fetch, 2} => tup([nil, el_(0)], ":ok"),
      {Enum, :random, 1} => el_(0),
      {Enum, :min, 1} => el_(0),
      {Enum, :max, 1} => el_(0),
      {Enum, :min, 2} => el_(0),
      {Enum, :max, 2} => el_(0),
      {Enum, :min, 3} => el_(0),
      {Enum, :max, 3} => el_(0),
      # Inspection only.
      {Enum, :count, 1} => :none,
      {Enum, :empty?, 1} => :none,
      {Enum, :member?, 2} => :none,
      {Enum, :sum, 1} => :none,
      {Enum, :product, 1} => :none,
      {Enum, :join, 1} => :none,
      {Enum, :join, 2} => :none,
      # Funs run on each element.
      {Enum, :each, 2} => run(1, [el_(0)], :none),
      {Enum, :map, 2} => run(1, [el_(0)], list(:result)),
      {Enum, :flat_map, 2} => run(1, [el_(0)], list(el(:result))),
      {Enum, :filter, 2} => run(1, [el_(0)], a(0)),
      {Enum, :reject, 2} => run(1, [el_(0)], a(0)),
      {Enum, :take_while, 2} => run(1, [el_(0)], a(0)),
      {Enum, :drop_while, 2} => run(1, [el_(0)], a(0)),
      {Enum, :uniq_by, 2} => run(1, [el_(0)], a(0)),
      {Enum, :dedup_by, 2} => run(1, [el_(0)], a(0)),
      {Enum, :sort_by, 2} => run(1, [el_(0)], a(0)),
      {Enum, :sort_by, 3} => run(1, [el_(0)], a(0)),
      {Enum, :chunk_by, 2} => run(1, [el_(0)], list(a(0))),
      {Enum, :find, 2} => run(1, [el_(0)], el_(0)),
      {Enum, :find, 3} => run(2, [el_(0)], u([el_(0), a(1)])),
      {Enum, :find_value, 2} => run(1, [el_(0)], :result),
      {Enum, :find_value, 3} => run(2, [el_(0)], u([:result, a(1)])),
      {Enum, :min_by, 2} => run(1, [el_(0)], el_(0)),
      {Enum, :max_by, 2} => run(1, [el_(0)], el_(0)),
      {Enum, :min_by, 3} => run(1, [el_(0)], el_(0)),
      {Enum, :max_by, 3} => run(1, [el_(0)], el_(0)),
      {Enum, :min_by, 4} => run(1, [el_(0)], el_(0)),
      {Enum, :max_by, 4} => run(1, [el_(0)], el_(0)),
      {Enum, :any?, 2} => run(1, [el_(0)], :none),
      {Enum, :all?, 2} => run(1, [el_(0)], :none),
      {Enum, :count, 2} => run(1, [el_(0)], :none),
      {Enum, :find_index, 2} => run(1, [el_(0)], :none),
      {Enum, :sum_by, 2} => run(1, [el_(0)], :none),
      {Enum, :product_by, 2} => run(1, [el_(0)], :none),
      {Enum, :map_join, 2} => run(1, [el_(0)], :none),
      {Enum, :map_join, 3} => run(2, [el_(0)], :none),
      {Enum, :frequencies_by, 2} => run(1, [el_(0)], {:map, :result, :none}),
      {Enum, :split_with, 2} => run(1, [el_(0)], tup([a(0), a(0)])),
      {Enum, :split_while, 2} => run(1, [el_(0)], tup([a(0), a(0)])),
      {Enum, :group_by, 2} => run(1, [el_(0)], {:map, :result, list(el_(0))}),
      {Enum, :group_by, 3} => run(2, [el_(0)], {:map, :none, list(:result)}, [{1, [el_(0)]}]),
      {Enum, :reduce, 2} => run(1, [el_(0), u([el_(0), :result])], u([el_(0), :result])),
      {Enum, :reduce, 3} => run(2, [el_(0), u([a(1), :result])], u([a(1), :result])),
      {Enum, :reduce_while, 3} =>
        run(2, [el_(0), u([a(1), second(:result)])], u([a(1), second(:result)])),
      {Enum, :map_reduce, 3} =>
        run(
          2,
          [el_(0), u([a(1), second(:result)])],
          tup([list(first(:result)), u([a(1), second(:result)])])
        ),
      {Enum, :flat_map_reduce, 3} =>
        run(
          2,
          [el_(0), u([a(1), second(:result)])],
          tup([list(el(first(:result))), u([a(1), second(:result)])])
        ),
      {Enum, :scan, 2} => run(1, [el_(0), u([el_(0), :result])], list(:result)),
      {Enum, :scan, 3} => run(2, [el_(0), u([a(1), :result])], list(:result)),
      {Enum, :map_every, 3} => run(2, [el_(0)], list(u([el_(0), :result]))),
      {Enum, :map_intersperse, 3} => run(2, [el_(0)], list(u([:result, a(1)]))),
      {Enum, :with_index, 2} =>
        {:fun_or, 1, run(1, [el_(0), :none], list(:result)), list(tup([el_(0), nil]))},
      {Enum, :zip_with, 3} => run(2, [el_(0), el_(1)], list(:result)),
      {Enum, :into, 3} => run(2, [el_(0)], {:into, :result, 1})
    }
  end

  # ── Stream: a stream is the list it would enumerate ─────────────────

  defp stream do
    %{
      {Stream, :map, 2} => run(1, [el_(0)], list(:result)),
      {Stream, :flat_map, 2} => run(1, [el_(0)], list(el(:result))),
      {Stream, :filter, 2} => run(1, [el_(0)], a(0)),
      {Stream, :reject, 2} => run(1, [el_(0)], a(0)),
      {Stream, :each, 2} => run(1, [el_(0)], a(0)),
      {Stream, :take_while, 2} => run(1, [el_(0)], a(0)),
      {Stream, :drop_while, 2} => run(1, [el_(0)], a(0)),
      {Stream, :uniq_by, 2} => run(1, [el_(0)], a(0)),
      {Stream, :dedup_by, 2} => run(1, [el_(0)], a(0)),
      {Stream, :chunk_by, 2} => run(1, [el_(0)], list(a(0))),
      {Stream, :map_every, 3} => run(2, [el_(0)], list(u([el_(0), :result]))),
      {Stream, :scan, 2} => run(1, [el_(0), u([el_(0), :result])], list(:result)),
      {Stream, :scan, 3} => run(2, [el_(0), u([a(1), :result])], list(:result)),
      {Stream, :zip_with, 3} => run(2, [el_(0), el_(1)], list(:result)),
      {Stream, :with_index, 2} =>
        {:fun_or, 1, run(1, [el_(0), :none], list(:result)), list(tup([el_(0), nil]))},
      {Stream, :with_index, 1} => list(tup([el_(0), nil])),
      {Stream, :take, 2} => a(0),
      {Stream, :drop, 2} => a(0),
      {Stream, :take_every, 2} => a(0),
      {Stream, :drop_every, 2} => a(0),
      {Stream, :uniq, 1} => a(0),
      {Stream, :dedup, 1} => a(0),
      {Stream, :concat, 1} => list(el(el_(0))),
      {Stream, :concat, 2} => u([a(0), a(1)]),
      {Stream, :zip, 1} => list(tup([el(el_(0)), el(el_(0))])),
      {Stream, :zip, 2} => list(tup([el_(0), el_(1)])),
      {Stream, :chunk_every, 2} => list(a(0)),
      {Stream, :chunk_every, 3} => list(a(0)),
      {Stream, :chunk_every, 4} => list(u([a(0), a(3)])),
      {Stream, :intersperse, 2} => list(u([el_(0), a(1)])),
      {Stream, :run, 1} => :none
    }
  end

  # ── List ────────────────────────────────────────────────────────────

  defp list_module do
    %{
      {List, :first, 1} => el_(0),
      {List, :first, 2} => u([el_(0), a(1)]),
      {List, :last, 1} => el_(0),
      {List, :last, 2} => u([el_(0), a(1)]),
      {List, :flatten, 1} => list(u([el_(0), el(el_(0))])),
      {List, :flatten, 2} => list(u([el_(0), el(el_(0)), el_(1)])),
      {List, :wrap, 1} => u([a(0), list(a(0))]),
      {List, :insert_at, 3} => {:cons, a(2), a(0)},
      {List, :replace_at, 3} => {:cons, a(2), a(0)},
      {List, :update_at, 3} => run(2, [el_(0)], {:cons, :result, a(0)}),
      {List, :delete, 2} => a(0),
      {List, :delete_at, 2} => a(0),
      {List, :pop_at, 2} => tup([el_(0), a(0)]),
      {List, :pop_at, 3} => tup([u([el_(0), a(2)]), a(0)]),
      {List, :duplicate, 2} => list(a(0)),
      {List, :zip, 1} => list(tup([el(el_(0)), el(el_(0))])),
      {List, :keyfind, 3} => el_(0),
      {List, :keyfind, 4} => u([el_(0), a(3)]),
      {List, :keyfind!, 3} => el_(0),
      {List, :keystore, 4} => {:cons, a(3), a(0)},
      {List, :keyreplace, 4} => {:cons, a(3), a(0)},
      {List, :keydelete, 3} => a(0),
      {List, :keytake, 3} => tup([el_(0), a(0)]),
      {List, :keysort, 2} => a(0),
      {List, :keysort, 3} => a(0),
      {List, :foldl, 3} => run(2, [el_(0), u([a(1), :result])], u([a(1), :result])),
      {List, :foldr, 3} => run(2, [el_(0), u([a(1), :result])], u([a(1), :result])),
      {List, :keymember?, 3} => :none,
      {List, :ascii_printable?, 1} => :none
    }
  end

  # ── Map ─────────────────────────────────────────────────────────────

  defp map_module do
    %{
      {Map, :values, 1} => list(values(0)),
      {Map, :keys, 1} => list(keys(0)),
      {Map, :to_list, 1} => list(el_(0)),
      {Map, :new, 1} => from_pairs(el_(0)),
      {Map, :new, 2} => run(1, [el_(0)], from_pairs(:result)),
      {Map, :merge, 2} => u([a(0), a(1)]),
      {Map, :delete, 2} => a(0),
      {Map, :drop, 2} => a(0),
      {Map, :take, 2} => a(0),
      {Map, :from_struct, 1} => a(0),
      {Map, :split, 2} => tup([a(0), a(0)]),
      {Map, :intersect, 2} => a(1),
      {Map, :replace, 3} => {:put, a(0), 1, a(2)},
      {Map, :replace!, 3} => {:put, a(0), 1, a(2)},
      {Map, :put_new, 3} => {:put, a(0), 1, a(2)},
      {Map, :pop, 2} => tup([{:field, a(0), 1}, a(0)]),
      {Map, :pop, 3} => tup([u([{:field, a(0), 1}, a(2)]), a(0)]),
      {Map, :pop!, 2} => tup([{:field, a(0), 1}, a(0)]),
      {Map, :update, 4} => run(3, [{:entry, a(0), 1}], {:put, a(0), 1, u([:result, a(2)])}),
      {Map, :update!, 3} => run(2, [{:entry, a(0), 1}], {:put, a(0), 1, :result}),
      {Map, :get_lazy, 3} => run(2, [], u([{:field, a(0), 1}, :result])),
      {Map, :put_new_lazy, 3} => run(2, [], {:put, a(0), 1, :result}),
      {Map, :filter, 2} => run(1, [el_(0)], a(0)),
      {Map, :reject, 2} => run(1, [el_(0)], a(0)),
      {Map, :has_key?, 2} => :none,
      {Map, :equal?, 2} => :none
    }
  end

  # ── Keyword: a list of {key, value} pairs ───────────────────────────

  defp keyword do
    %{
      {Keyword, :get, 2} => values(0),
      {Keyword, :get, 3} => u([values(0), a(2)]),
      {Keyword, :fetch!, 2} => values(0),
      {Keyword, :fetch, 2} => tup([nil, values(0)], ":ok"),
      {Keyword, :get_values, 2} => list(values(0)),
      {Keyword, :values, 1} => list(values(0)),
      {Keyword, :keys, 1} => list(keys(0)),
      {Keyword, :put, 3} => {:cons, tup([a(1), a(2)]), a(0)},
      {Keyword, :put_new, 3} => {:cons, tup([a(1), a(2)]), a(0)},
      {Keyword, :merge, 2} => u([a(0), a(1)]),
      {Keyword, :delete, 2} => a(0),
      {Keyword, :take, 2} => a(0),
      {Keyword, :drop, 2} => a(0),
      {Keyword, :new, 1} => list(el_(0)),
      {Keyword, :to_list, 1} => a(0),
      {Keyword, :split, 2} => tup([a(0), a(0)]),
      {Keyword, :pop, 2} => tup([values(0), a(0)]),
      {Keyword, :pop, 3} => tup([u([values(0), a(2)]), a(0)]),
      {Keyword, :pop!, 2} => tup([values(0), a(0)]),
      {Keyword, :filter, 2} => run(1, [el_(0)], a(0)),
      {Keyword, :reject, 2} => run(1, [el_(0)], a(0)),
      {Keyword, :has_key?, 2} => :none,
      # `term[key]` on a keyword list: Access.get/2's map read is TermFlow's
      # own (`@field_reads`); this adds a keyword list's values.
      {Access, :get, 2} => values(0),
      {Access, :get, 3} => u([values(0), a(2)])
    }
  end

  # ── MapSet: the list of its members ─────────────────────────────────

  defp map_set do
    %{
      {MapSet, :new, 1} => list(el_(0)),
      {MapSet, :new, 2} => run(1, [el_(0)], list(:result)),
      {MapSet, :to_list, 1} => list(el_(0)),
      {MapSet, :put, 2} => {:cons, a(1), a(0)},
      {MapSet, :delete, 2} => a(0),
      {MapSet, :union, 2} => u([a(0), a(1)]),
      {MapSet, :difference, 2} => a(0),
      {MapSet, :intersection, 2} => a(0),
      {MapSet, :filter, 2} => run(1, [el_(0)], a(0)),
      {MapSet, :reject, 2} => run(1, [el_(0)], a(0)),
      {MapSet, :split_with, 2} => run(1, [el_(0)], tup([a(0), a(0)])),
      {MapSet, :member?, 2} => :none,
      {MapSet, :size, 1} => :none
    }
  end

  # ── Tuple and the container BIFs called as functions ────────────────

  defp tuples do
    %{
      {Tuple, :to_list, 1} => list({:read, a(0), "**"}),
      {:erlang, :tuple_to_list, 1} => list({:read, a(0), "**"}),
      {:erlang, :element, 2} => {:index, a(1), 0},
      {:erlang, :setelement, 3} => {:setelement, 0, a(1), a(2)},
      {:erlang, :++, 2} => u([a(0), a(1)]),
      {:erlang, :--, 2} => a(0),
      {:erlang, :hd, 1} => el_(0),
      {:erlang, :tl, 1} => a(0),
      {:erlang, :length, 1} => :none,
      {:erlang, :tuple_size, 1} => :none,
      {:erlang, :map_size, 1} => :none,
      {:erlang, :is_map_key, 2} => :none,
      # A term raised as an error ends the flow it was in: the compiler's own
      # failures (`{:badmatch, v}`, `{:badmap, v}`, `{:case_clause, v}`) hand
      # it the value they failed on. `throw/1` is control flow: what it
      # throws is caught and used, and it stays an escape.
      {:erlang, :error, 1} => :none,
      {:erlang, :error, 2} => :none,
      {:erlang, :error, 3} => :none,
      {:erlang, :exit, 1} => :none,
      {:erlang, :raise, 3} => :none,
      {Kernel, :inspect, 1} => :none,
      {Kernel, :inspect, 2} => :none,
      {IO, :inspect, 1} => a(0),
      {IO, :inspect, 2} => a(0),
      {IO, :inspect, 3} => a(1)
    }
  end

  # ── :lists: the fun before the list ─────────────────────────────────

  defp lists do
    %{
      {:lists, :reverse, 1} => a(0),
      {:lists, :reverse, 2} => u([a(0), a(1)]),
      {:lists, :append, 1} => list(el(el_(0))),
      {:lists, :append, 2} => u([a(0), a(1)]),
      {:lists, :flatten, 1} => list(u([el_(0), el(el_(0))])),
      {:lists, :flatten, 2} => list(u([el_(0), el(el_(0)), el_(1)])),
      {:lists, :nth, 2} => el_(1),
      {:lists, :nthtail, 2} => a(1),
      {:lists, :last, 1} => el_(0),
      {:lists, :droplast, 1} => a(0),
      {:lists, :sublist, 2} => a(0),
      {:lists, :sublist, 3} => a(0),
      {:lists, :delete, 2} => a(1),
      {:lists, :subtract, 2} => a(0),
      {:lists, :sort, 1} => a(0),
      {:lists, :sort, 2} => a(1),
      {:lists, :usort, 1} => a(0),
      {:lists, :usort, 2} => a(1),
      {:lists, :keysort, 2} => a(1),
      {:lists, :ukeysort, 2} => a(1),
      {:lists, :keyfind, 3} => el_(2),
      {:lists, :keystore, 4} => {:cons, a(3), a(2)},
      {:lists, :keyreplace, 4} => {:cons, a(3), a(2)},
      {:lists, :keydelete, 3} => a(2),
      {:lists, :keytake, 3} => tup([nil, el_(2), a(2)], ":value"),
      {:lists, :keymerge, 3} => u([a(1), a(2)]),
      {:lists, :merge, 2} => u([a(0), a(1)]),
      {:lists, :merge, 1} => list(el(el_(0))),
      {:lists, :zip, 2} => list(tup([el_(0), el_(1)])),
      {:lists, :unzip, 1} => tup([list(keys(0)), list(values(0))]),
      {:lists, :enumerate, 1} => list(tup([nil, el_(0)])),
      {:lists, :enumerate, 2} => list(tup([nil, el_(1)])),
      {:lists, :duplicate, 2} => list(a(1)),
      {:lists, :split, 2} => tup([a(1), a(1)]),
      {:lists, :uniq, 1} => a(0),
      {:lists, :max, 1} => el_(0),
      {:lists, :min, 1} => el_(0),
      {:lists, :member, 2} => :none,
      {:lists, :keymember, 3} => :none,
      {:lists, :sum, 1} => :none,
      {:lists, :foreach, 2} => run(0, [el_(1)], :none),
      {:lists, :map, 2} => run(0, [el_(1)], list(:result)),
      {:lists, :flatmap, 2} => run(0, [el_(1)], list(el(:result))),
      {:lists, :filter, 2} => run(0, [el_(1)], a(1)),
      {:lists, :takewhile, 2} => run(0, [el_(1)], a(1)),
      {:lists, :dropwhile, 2} => run(0, [el_(1)], a(1)),
      {:lists, :uniq, 2} => run(0, [el_(1)], a(1)),
      {:lists, :partition, 2} => run(0, [el_(1)], tup([a(1), a(1)])),
      {:lists, :splitwith, 2} => run(0, [el_(1)], tup([a(1), a(1)])),
      {:lists, :any, 2} => run(0, [el_(1)], :none),
      {:lists, :all, 2} => run(0, [el_(1)], :none),
      {:lists, :search, 2} => run(0, [el_(1)], tup([nil, el_(1)], ":value")),
      {:lists, :filtermap, 2} => run(0, [el_(1)], list(u([el_(1), second(:result)]))),
      {:lists, :foldl, 3} => run(0, [el_(2), u([a(1), :result])], u([a(1), :result])),
      {:lists, :foldr, 3} => run(0, [el_(2), u([a(1), :result])], u([a(1), :result])),
      {:lists, :mapfoldl, 3} =>
        run(
          0,
          [el_(2), u([a(1), second(:result)])],
          tup([list(first(:result)), u([a(1), second(:result)])])
        ),
      {:lists, :mapfoldr, 3} =>
        run(
          0,
          [el_(2), u([a(1), second(:result)])],
          tup([list(first(:result)), u([a(1), second(:result)])])
        ),
      {:lists, :zipwith, 3} => run(0, [el_(1), el_(2)], list(:result))
    }
  end

  # ── :maps: the key before the map ───────────────────────────────────

  defp maps do
    %{
      {:maps, :values, 1} => list(values(0)),
      {:maps, :keys, 1} => list(keys(0)),
      {:maps, :to_list, 1} => list(el_(0)),
      {:maps, :from_list, 1} => from_pairs(el_(0)),
      {:maps, :from_keys, 2} => {:map, el_(0), a(1)},
      {:maps, :merge, 2} => u([a(0), a(1)]),
      {:maps, :remove, 2} => a(1),
      {:maps, :without, 2} => a(1),
      {:maps, :with, 2} => a(1),
      # Map.intersect/2 compiles to it: the second map's values.
      {:maps, :intersect, 2} => a(1),
      {:maps, :take, 2} => tup([{:field, a(1), 0}, a(1)]),
      {:maps, :update, 3} => {:put, a(2), 0, a(1)},
      {:maps, :is_key, 2} => :none,
      {:maps, :size, 1} => :none,
      {:maps, :filter, 2} => run(0, [keys(1), values(1)], a(1)),
      {:maps, :map, 2} => run(0, [keys(1), values(1)], {:map, keys(1), :result}),
      {:maps, :fold, 3} => run(0, [keys(2), values(2), u([a(1), :result])], u([a(1), :result])),
      {:maps, :foreach, 2} => run(0, [keys(1), values(1)], :none)
    }
  end

  @doc """
  The calls that run a fun: `%{mfa => {fun_position, kept?}}`, `kept?`
  when what the call answers holds what the fun answers.
  """
  @spec runs() :: %{mfa() => {non_neg_integer(), boolean()}}
  def runs do
    for {mfa, model} <- models(), {at, answer} <- run_of(model), into: %{} do
      {mfa, {at, answer_kept?(answer)}}
    end
  end

  defp run_of({:run, at, _params, answer, _others}), do: [{at, answer}]
  defp run_of({:fun_or, _at, running, _plain}), do: run_of(running)
  defp run_of(_spec), do: []

  # Calls running a fun on elements that may stop, or skip some: a fun
  # they run is not run on every element. A stream runs nothing until it
  # is enumerated.
  @partial [
    {Enum, :find, 2},
    {Enum, :find, 3},
    {Enum, :find_value, 2},
    {Enum, :find_value, 3},
    {Enum, :find_index, 2},
    {Enum, :any?, 2},
    {Enum, :all?, 2},
    {Enum, :take_while, 2},
    {Enum, :drop_while, 2},
    {Enum, :split_while, 2},
    {Enum, :reduce, 2},
    {Enum, :reduce_while, 3},
    {Enum, :scan, 2},
    {Enum, :map_every, 3},
    {Enum, :flat_map_reduce, 3},
    {Enum, :zip_with, 3},
    {:lists, :any, 2},
    {:lists, :all, 2},
    {:lists, :search, 2},
    {:lists, :takewhile, 2},
    {:lists, :dropwhile, 2},
    {:lists, :splitwith, 2},
    {:lists, :zipwith, 3}
  ]

  @doc """
  The calls that run a fun on every element of a list, the element its
  first parameter: `%{mfa => {list_position, fun_position}}`. Whatever
  the fun does to its element is done to every element.
  """
  @spec every_element() :: %{mfa() => {non_neg_integer(), non_neg_integer()}}
  def every_element do
    for {{mod, _, _} = mfa, model} <- models(),
        mod != Stream,
        mfa not in @partial,
        {:run, at, [{:elements, {:arg, list}} | _], _answer, _others} <- run_models(model),
        into: %{},
        do: {mfa, {list, at}}
  end

  defp run_models({:fun_or, _at, running, _plain}), do: [running]
  defp run_models({:run, _, _, _, _} = model), do: [model]
  defp run_models(_spec), do: []

  @doc """
  The argument positions a call hands back in what it answers, whole or
  in part: `Enum.reverse/1`'s list, `Map.put/3`'s map and value. Only for
  a call answering by a spec (not one running a fun) and not an
  inspection (`:none`).
  """
  @spec carried_args(mfa()) :: [non_neg_integer()]
  def carried_args(mfa) do
    case Map.fetch(models(), mfa) do
      {:ok, {:run, _, _, _, _}} -> []
      {:ok, {:fun_or, _, _, _}} -> []
      {:ok, spec} -> spec |> args_in() |> Enum.uniq() |> Enum.sort()
      :error -> []
    end
  end

  defp args_in({:arg, n}), do: [n]
  defp args_in({:into, elements, at}), do: [at | args_in(elements)]
  defp args_in(spec) when is_tuple(spec), do: spec |> Tuple.to_list() |> Enum.flat_map(&args_in/1)
  defp args_in(specs) when is_list(specs), do: Enum.flat_map(specs, &args_in/1)
  defp args_in(_other), do: []

  @doc "Whether an answer spec holds what the fun the call runs answers."
  @spec answer_kept?(spec() | [spec()] | term()) :: boolean()
  def answer_kept?(:result), do: true

  def answer_kept?(spec) when is_tuple(spec),
    do: spec |> Tuple.to_list() |> Enum.any?(&answer_kept?/1)

  def answer_kept?(specs) when is_list(specs), do: Enum.any?(specs, &answer_kept?/1)
  def answer_kept?(_other), do: false

  @doc "Every modeled call: a value spec, or what a call running a fun does."
  @spec models() :: %{mfa() => model()}
  def models do
    [
      enum(),
      stream(),
      list_module(),
      map_module(),
      keyword(),
      map_set(),
      tuples(),
      lists(),
      maps()
    ]
    |> Enum.reduce(fn table, acc ->
      Map.merge(acc, table, fn mfa, _, _ ->
        raise ArgumentError, "#{inspect(mfa)} is modeled twice"
      end)
    end)
  end
end
