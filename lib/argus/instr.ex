defmodule Argus.Instr do
  @moduledoc """
  What each BEAM instruction reads, writes and where control goes after
  it: the one reading of the instruction set, which the emitter's `def`,
  `use` and `next` facts are made from.

  Instructions are taken as `:beam_disasm` prints them on OTP 28 and 29
  — raw, with typed registers (`{:tr, reg, type}`), or after
  `Argus.Pipeline.Normalize` has stripped them; both read the same. OTP
  29 adds the native-record instructions (`-record #name{...}`), which
  no OTP or Elixir module compiles to yet.

  ## Semantics

  Every opcode is spelled out, so an instruction this module has never
  seen is `known?/1` false rather than silently "writes nothing". The
  test suite disassembles OTP, Elixir and the dependencies and asserts
  that every instruction in them is known.

    * `defs/1` — the registers the instruction writes. A non-tail call
      writes `x0` (its result); it also destroys every other `x`
      register, which `clobbers?/2` answers rather than `defs/1`, since
      "every x register" is not a list.
    * `uses/1` — the registers it reads, including a call's argument
      registers and the fun of `call_fun`.
    * `targets/1` — the labels control may reach from it other than by
      falling through: fail labels (a test's, a guard BIF's, a map
      instruction's, a binary match's), select arms, jumps, the receive
      loop's transfers and the handler of a `try` or `catch`.
    * `falls_through?/1` — whether the next instruction can run after it.
      Not after a jump, a select, a return, a tail call, a raise
      (`badmatch`, `case_end`, `if_end`, the `raise` BIF, ...), `wait`,
      `loop_rec_end` or `func_info`. `raw_raise` does fall through: it is
      `erlang:raise/3`, which returns `badarg` for an invalid class.

  Three instructions write registers the operands do not name: at a
  `try`/`catch` handler the VM materializes the exception, so
  `try_case` writes `x0`–`x2` (class, reason, stacktrace) and
  `catch_end` writes `x0`; `build_stacktrace` rewrites `x0`. And `trim`
  renumbers the stack frame, so `trim N, R` writes `y0..y(R-1)` from
  `yN..y(N+R-1)` — it is a copy, like `move` and `swap` (`copy_source/2`).
  """

  @type reg :: {:x, non_neg_integer()} | {:y, non_neg_integer()} | {:fr, non_neg_integer()}
  @type label :: pos_integer()
  @type instr :: tuple() | atom()

  # How control leaves an instruction besides its targets: `:next` falls
  # through, `:exit` leaves the function (a return or a tail call), and
  # `:stop` goes only to the targets, or raises.
  @typep flow :: :next | :exit | :stop
  @typep sem :: {[reg()], [reg()], [label()], flow()}

  # The bs_match commands that extract a segment, naming the destination
  # last; the rest only test or skip.
  @bs_extractors [:integer, :binary, :float, :get_tail, :utf8, :utf16, :utf32]
  @bs_checks [:ensure_at_least, :ensure_exactly, :skip, :"=:="]

  # The test instructions that write, spelled with their destination as
  # the last argument.
  @writing_tests [:bs_get_utf8, :bs_get_utf16, :bs_get_utf32]

  @doc "The registers `instr` writes; none for an instruction that is not `known?/1`."
  @spec defs(instr()) :: [reg()]
  def defs(instr), do: field(instr, 0, [])

  @doc "The registers `instr` reads; none for an instruction that is not `known?/1`."
  @spec uses(instr()) :: [reg()]
  def uses(instr), do: field(instr, 1, [])

  @doc "The labels control may reach from `instr` other than by falling through."
  @spec targets(instr()) :: [label()]
  def targets(instr), do: field(instr, 2, [])

  @doc """
  Whether the next instruction can run after `instr`. An instruction that
  is not `known?/1` is taken to fall through, as the emitter always did.
  """
  @spec falls_through?(instr()) :: boolean()
  def falls_through?(instr), do: field(instr, 3, :next) == :next

  @doc """
  Whether `instr` leaves the function: a `return` or a tail call. The
  instruction laid out before a label is often one of these, and the
  code before it belongs to another path.
  """
  @spec exits?(instr()) :: boolean()
  def exits?(instr), do: field(instr, 3, :next) == :exit

  @doc "Whether `instr` is a call that returns here, leaving its result in `x0`."
  @spec call?(instr()) :: boolean()
  def call?({op, _, _}) when op in [:call, :call_ext], do: true
  def call?({:call_fun, _}), do: true
  def call?({:call_fun2, _, _, _}), do: true
  def call?({:apply, _}), do: true
  def call?(_instr), do: false

  @tail_call_ops [:call_only, :call_ext_only, :call_last, :call_ext_last, :apply_last]
  @tail_call_names Enum.map(@tail_call_ops, &Atom.to_string/1)

  @doc "Whether `instr` is a tail call: a call whose callee returns for this function."
  @spec tail_call?(instr()) :: boolean()
  def tail_call?(instr) when is_tuple(instr) and tuple_size(instr) > 0,
    do: tail_call_op?(elem(instr, 0)) and known?(instr)

  def tail_call?(_instr), do: false

  @doc """
  Whether an instruction named `op` (an atom, or the string an
  `instruction` fact's `op` column holds) is a tail call — what a reader
  holding only the name, like `Argus.Cfg`, asks.
  """
  @spec tail_call_op?(atom() | String.t()) :: boolean()
  def tail_call_op?(op) when is_atom(op), do: op in @tail_call_ops
  def tail_call_op?(op) when is_binary(op), do: op in @tail_call_names

  @doc "Whether `instr` writes `reg` (a plain or typed register)."
  @spec defines?(instr(), term()) :: boolean()
  def defines?(instr, reg), do: register(reg) in defs(instr)

  @doc """
  Whether the value `reg` held before `instr` is gone after it: `instr`
  writes it; `instr` is a call and `reg` an `x` register (a call destroys
  them all); `instr` renumbers or drops the stack frame (`trim`,
  `deallocate`) and `reg` is a `y` register, whose slot now means
  another or none; or `instr` is not `known?/1` — an instruction this
  module cannot read might write anything.
  """
  @spec clobbers?(instr(), term()) :: boolean()
  def clobbers?(instr, reg) do
    reg = register(reg)

    case semantics(instr) do
      :unknown ->
        true

      {defs, _uses, _targets, _flow} ->
        reg in defs or (call?(instr) and match?({:x, _}, reg)) or
          (frame_change?(instr) and match?({:y, _}, reg))
    end
  end

  defp frame_change?({:trim, _, _}), do: true
  defp frame_change?({:deallocate, _}), do: true
  defp frame_change?(_instr), do: false

  @doc """
  The operand `instr` copied into `reg`, when `instr` is a copy: the
  source of a `move`/`fmove`, the other register of a `swap`, the
  register a `trim` renumbered into it. `nil` for anything else,
  including a copy that did not write `reg`. The empty list, which BEAM
  assembly spells `nil`, is `{:literal, []}` here, so `nil` means only
  "not a copy".
  """
  @spec copy_source(instr(), term()) :: term() | nil
  def copy_source(instr, reg), do: do_copy_source(instr, register(reg))

  defp do_copy_source({op, src, dst}, reg) when op in [:move, :fmove] do
    cond do
      register(dst) != reg -> nil
      src == nil -> {:literal, []}
      true -> register(src)
    end
  end

  defp do_copy_source({:swap, a, b}, reg) do
    cond do
      register(a) == reg -> register(b)
      register(b) == reg -> register(a)
      true -> nil
    end
  end

  defp do_copy_source({:trim, n, remaining}, {:y, k}) when k < remaining, do: {:y, k + n}
  defp do_copy_source(_instr, _reg), do: nil

  @doc """
  The registers holding a value after `instr`, given the ones holding it
  before: a register `instr` writes stops holding it unless `instr` copied
  it there from one that did (a `move`, `swap` or `trim`), and a call
  destroys every `x` register. What a forward walk that follows a value
  through the registers applies at each instruction it does not handle
  itself.
  """
  @spec carry(instr(), Enumerable.t()) :: [reg()]
  def carry(instr, holding) do
    holding = Enum.map(holding, &register/1)
    copied = for dst <- defs(instr), copy_source(instr, dst) in holding, do: dst
    kept = Enum.reject(holding, &clobbers?(instr, &1))
    Enum.uniq(kept ++ copied)
  end

  @doc "Whether this module can read `instr`."
  @spec known?(instr()) :: boolean()
  def known?(instr), do: semantics(instr) != :unknown

  @doc "A register operand without its type annotation."
  @spec register(term()) :: term()
  def register({:tr, reg, _type}), do: reg
  def register(other), do: other

  @doc """
  The `x` or `y` register `operand` names, its type annotation stripped,
  or nil for any other operand: a literal, a float register, a label.
  """
  @spec slot(term()) :: {:x | :y, non_neg_integer()} | nil
  def slot({:tr, reg, _type}), do: slot(reg)
  def slot({kind, _n} = reg) when kind in [:x, :y], do: reg
  def slot(_operand), do: nil

  @doc "Each label of the function's `instrs` and the index it sits at."
  @spec labels([tuple()]) :: %{pos_integer() => non_neg_integer()}
  def labels(instrs) do
    for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}
  end

  # --- the table --------------------------------------------------------

  defp field(instr, n, unknown) do
    case semantics(instr) do
      :unknown -> unknown
      sem -> elem(sem, n)
    end
  end

  @spec semantics(instr()) :: sem() | :unknown

  # Markers and frame bookkeeping.
  defp semantics({:label, _}), do: {[], [], [], :next}
  defp semantics({:line, _}), do: {[], [], [], :next}
  defp semantics({:executable_line, _, _}), do: {[], [], [], :next}
  defp semantics({:debug_line, _, _, _, _}), do: {[], [], [], :next}
  defp semantics({:func_info, _, _, _}), do: {[], [], [], :stop}
  defp semantics(:int_code_end), do: {[], [], [], :stop}
  defp semantics(:on_load), do: {[], [], [], :next}
  defp semantics(:nif_start), do: {[], [], [], :next}
  defp semantics({:allocate, _, _}), do: {[], [], [], :next}
  defp semantics({:allocate_heap, _, _, _}), do: {[], [], [], :next}
  defp semantics({:test_heap, _, _}), do: {[], [], [], :next}
  defp semantics({:deallocate, _}), do: {[], [], [], :next}

  defp semantics({:trim, n, remaining}) when is_integer(n) and is_integer(remaining) do
    kept = 0..(remaining - 1)//1
    {Enum.map(kept, &{:y, &1}), Enum.map(kept, &{:y, &1 + n}), [], :next}
  end

  defp semantics({:init_yregs, {:list, regs}}), do: {regs(regs), [], [], :next}

  # Calls. Arguments travel in x0..x(arity-1) and the result in x0.
  defp semantics({:call, arity, _target}), do: {[{:x, 0}], args(arity), [], :next}
  defp semantics({:call_only, arity, _target}), do: {[], args(arity), [], :exit}
  defp semantics({:call_last, arity, _target, _dealloc}), do: {[], args(arity), [], :exit}
  defp semantics({:call_ext, arity, _target}), do: {[{:x, 0}], args(arity), [], :next}
  defp semantics({:call_ext_only, arity, _target}), do: {[], args(arity), [], :exit}
  defp semantics({:call_ext_last, arity, _target, _dealloc}), do: {[], args(arity), [], :exit}

  # call_fun reads the fun from x(arity); apply its module and function
  # from x(arity) and x(arity+1).
  defp semantics({:call_fun, arity}), do: {[{:x, 0}], args(arity + 1), [], :next}

  defp semantics({:call_fun2, _tag, arity, fun}),
    do: {[{:x, 0}], args(arity) ++ regs([fun]), [], :next}

  defp semantics({:apply, arity}), do: {[{:x, 0}], args(arity + 2), [], :next}
  defp semantics({:apply_last, arity, _dealloc}), do: {[], args(arity + 2), [], :exit}
  defp semantics(:return), do: {[], [{:x, 0}], [], :exit}

  # BIFs. The raise BIF never returns.
  defp semantics({:bif, :raise, fail, args, dst}),
    do: {regs([dst]), regs(args), fail(fail), :stop}

  defp semantics({:bif, _name, fail, args, dst}), do: {regs([dst]), regs(args), fail(fail), :next}

  defp semantics({:gc_bif, _name, fail, _live, args, dst}),
    do: {regs([dst]), regs(args), fail(fail), :next}

  # Moving data.
  defp semantics({:move, src, dst}), do: {regs([dst]), regs([src]), [], :next}
  defp semantics({:fmove, src, dst}), do: {regs([dst]), regs([src]), [], :next}
  defp semantics({:fconv, src, dst}), do: {regs([dst]), regs([src]), [], :next}
  defp semantics({:swap, a, b}), do: {regs([a, b]), regs([a, b]), [], :next}

  # Lists and tuples.
  defp semantics({:get_list, src, hd, tl}), do: {regs([hd, tl]), regs([src]), [], :next}
  defp semantics({:get_hd, src, dst}), do: {regs([dst]), regs([src]), [], :next}
  defp semantics({:get_tl, src, dst}), do: {regs([dst]), regs([src]), [], :next}
  defp semantics({:put_list, hd, tl, dst}), do: {regs([dst]), regs([hd, tl]), [], :next}

  defp semantics({:get_tuple_element, src, _index, dst}),
    do: {regs([dst]), regs([src]), [], :next}

  defp semantics({:set_tuple_element, value, tuple, _index}),
    do: {[], regs([value, tuple]), [], :next}

  defp semantics({:put_tuple2, dst, {:list, elements}}),
    do: {regs([dst]), regs(elements), [], :next}

  defp semantics({:update_record, _hint, _size, src, dst, {:list, updates}}),
    do: {regs([dst]), regs([src | updates]), [], :next}

  # Maps. Pairs alternate key and value (or key and destination).
  defp semantics({op, fail, src, dst, _live, {:list, pairs}})
       when op in [:put_map_assoc, :put_map_exact],
       do: {regs([dst]), regs([src | pairs]), fail(fail), :next}

  defp semantics({:get_map_elements, fail, src, {:list, pairs}}) do
    {keys, dsts} = unzip_pairs(pairs)
    {regs(dsts), regs([src | keys]), fail(fail), :next}
  end

  # OTP 29's native records read and build as maps do: pairs alternate
  # field name and destination (or value). A build with no source (`nil`)
  # makes a record afresh.
  defp semantics({:get_record_elements, fail, src, {:list, pairs}}) do
    {keys, dsts} = unzip_pairs(pairs)
    {regs(dsts), regs([src | keys]), fail(fail), :next}
  end

  defp semantics({:put_record, fail, _id, src, dst, {:list, pairs}}),
    do: {regs([dst]), regs([src | pairs]), fail(fail), :next}

  # Funs. A label-targeted make_fun3 names the fun's code, not a branch.
  defp semantics({:make_fun3, _target, _index, _uniq, dst, {:list, env}}),
    do: {regs([dst]), regs(env), [], :next}

  # Tests. Four shapes: operands in a list; a source and a field list
  # (has_map_fields); a live count before the list; a live count and a
  # destination after it (bs_start_match3, bs_get_integer2, ...).
  # OTP 29's native-record tests name their subject bare, not in a list:
  # is it any native record, is it this module's record of this name, may
  # this code read its fields. get_record_field is a guard read spelled
  # as a test, writing the field's value.
  defp semantics({:test, :is_record, fail, src}) when not is_list(src),
    do: {[], regs([src]), fail(fail), :next}

  defp semantics({:test, :is_record, fail, src, _module, _name}),
    do: {[], regs([src]), fail(fail), :next}

  defp semantics({:test, :is_record_accessible, fail, src, _scope}),
    do: {[], regs([src]), fail(fail), :next}

  defp semantics({:test, :get_record_field, fail, src, _id, _field, dst}),
    do: {regs([dst]), regs([src]), fail(fail), :next}

  defp semantics({:test, name, fail, args}) when name in @writing_tests and is_list(args) do
    {operands, [dst]} = Enum.split(args, -1)
    {regs([dst]), regs(operands), fail(fail), :next}
  end

  defp semantics({:test, _name, fail, args}) when is_list(args),
    do: {[], regs(args), fail(fail), :next}

  defp semantics({:test, _name, fail, src, {:list, fields}}),
    do: {[], regs([src | fields]), fail(fail), :next}

  defp semantics({:test, _name, fail, _live, args}) when is_list(args),
    do: {[], regs(args), fail(fail), :next}

  defp semantics({:test, _name, fail, _live, args, dst}) when is_list(args),
    do: {regs([dst]), regs(args), fail(fail), :next}

  # Control transfers.
  defp semantics({:jump, target}), do: {[], [], fail(target), :stop}

  defp semantics({op, src, fail, {:list, arms}}) when op in [:select_val, :select_tuple_arity],
    do: {[], regs([src]), Enum.uniq(fail(fail) ++ for({:f, l} <- arms, l > 0, do: l)), :stop}

  # Raises.
  defp semantics({:badmatch, value}), do: {[], regs([value]), [], :stop}
  defp semantics({:case_end, value}), do: {[], regs([value]), [], :stop}
  defp semantics({:badrecord, value}), do: {[], regs([value]), [], :stop}
  defp semantics({:try_case_end, value}), do: {[], regs([value]), [], :stop}
  defp semantics(:if_end), do: {[], [], [], :stop}

  # erlang:raise/3 inline: with an invalid class it does not raise but
  # returns badarg in x0, and the compiler emits the code that follows.
  defp semantics(:raw_raise), do: {[{:x, 0}], args(3), [], :next}

  # Exceptions. The handler label is where control lands when the
  # protected code raises: try_case leaves the class, reason and
  # stacktrace in x0-x2; catch_end leaves in x0 the protected
  # expression's value, which the normal path brought in x0, or the
  # caught one.
  defp semantics({:try, reg, handler}), do: {regs([reg]), [], fail(handler), :next}
  defp semantics({:catch, reg, handler}), do: {regs([reg]), [], fail(handler), :next}
  defp semantics({:try_end, reg}), do: {[], regs([reg]), [], :next}
  defp semantics({:try_case, reg}), do: {args(3), regs([reg]), [], :next}
  defp semantics({:catch_end, reg}), do: {[{:x, 0}], regs([reg]) ++ [{:x, 0}], [], :next}
  defp semantics(:build_stacktrace), do: {[{:x, 0}], [{:x, 0}], [], :next}

  # Messages. loop_rec takes the next message into its destination, or
  # branches to the wait block on an empty mailbox; wait and
  # loop_rec_end go back to the loop; wait_timeout goes back on a
  # message and falls through on the timeout.
  defp semantics(:send), do: {[{:x, 0}], args(2), [], :next}
  defp semantics({:loop_rec, fail, dst}), do: {regs([dst]), [], fail(fail), :next}
  defp semantics({:loop_rec_end, target}), do: {[], [], fail(target), :stop}
  defp semantics(:remove_message), do: {[], [], [], :next}
  defp semantics(:timeout), do: {[], [], [], :next}
  defp semantics({:wait, target}), do: {[], [], fail(target), :stop}
  defp semantics({:wait_timeout, target, timeout}), do: {[], regs([timeout]), fail(target), :next}
  defp semantics({:recv_marker_reserve, marker}), do: {regs([marker]), [], [], :next}
  defp semantics({:recv_marker_bind, marker, ref}), do: {[], regs([marker, ref]), [], :next}
  defp semantics({:recv_marker_clear, marker}), do: {[], regs([marker]), [], :next}
  defp semantics({:recv_marker_use, marker}), do: {[], regs([marker]), [], :next}

  # Binaries. bs_init_writable takes the size in x0 and leaves the
  # binary there.
  defp semantics({:bs_start_match4, fail, _live, src, dst}),
    do: {regs([dst]), regs([src]), fail(fail), :next}

  defp semantics({:bs_get_tail, src, dst, _live}), do: {regs([dst]), regs([src]), [], :next}
  defp semantics({:bs_get_position, src, dst, _live}), do: {regs([dst]), regs([src]), [], :next}
  defp semantics({:bs_set_position, src, pos}), do: {[], regs([src, pos]), [], :next}
  defp semantics(:bs_init_writable), do: {[{:x, 0}], [{:x, 0}], [], :next}

  defp semantics({:bs_create_bin, fail, _alloc, _live, _unit, dst, {:list, segments}}),
    do: {regs([dst]), regs(segments), fail(fail), :next}

  defp semantics({:bs_match, fail, ctx, {:commands, commands}}) when is_list(commands) do
    case bs_commands(commands, [], []) do
      {defs, uses} -> {defs, regs([ctx]) ++ uses, fail(fail), :next}
      :unknown -> :unknown
    end
  end

  defp semantics(_instr), do: :unknown

  defp bs_commands([], defs, uses), do: {Enum.reverse(defs), Enum.reverse(uses)}

  defp bs_commands([command | rest], defs, uses)
       when is_tuple(command) and tuple_size(command) > 1 do
    fields = Tuple.to_list(command)

    case hd(fields) do
      tag when tag in @bs_extractors ->
        {operands, [dst]} = fields |> tl() |> Enum.split(-1)
        bs_commands(rest, regs([dst]) ++ defs, Enum.reverse(regs(operands)) ++ uses)

      tag when tag in @bs_checks ->
        bs_commands(rest, defs, Enum.reverse(regs(tl(fields))) ++ uses)

      _unknown ->
        :unknown
    end
  end

  defp bs_commands(_commands, _defs, _uses), do: :unknown

  # --- operands ---------------------------------------------------------

  defp args(n), do: Enum.map(0..(n - 1)//1, &{:x, &1})

  # The register operands among `operands`, typed ones unwrapped. A
  # literal is never looked into: a `{:literal, [x: 0]}` holds data.
  defp regs(operands) do
    for operand <- operands, reg = register(operand), register?(reg), do: reg
  end

  defp register?({kind, n}) when kind in [:x, :y, :fr] and is_integer(n), do: true
  defp register?(_operand), do: false

  defp fail({:f, label}) when is_integer(label) and label > 0, do: [label]
  defp fail(_no_label), do: []

  defp unzip_pairs(pairs), do: unzip_pairs(pairs, [], [])
  defp unzip_pairs([key, value | rest], ks, vs), do: unzip_pairs(rest, [key | ks], [value | vs])
  defp unzip_pairs(_rest, ks, vs), do: {Enum.reverse(ks), Enum.reverse(vs)}
end
