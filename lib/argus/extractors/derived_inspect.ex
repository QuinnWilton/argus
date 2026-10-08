defmodule Argus.Extractors.DerivedInspect do
  @moduledoc """
  The fields a derived `Inspect` implementation prints.

  `@derive {Inspect, except: [...]}` and `@derive {Inspect, only: [...]}`
  keep fields out of `inspect/1` the way Ecto's `redact: true` does —
  which is no coincidence: Ecto implements `redact: true` by deriving
  `Inspect` with `except:` its redacted fields, and only when the schema
  derives no `Inspect` of its own. So a schema that derives `Inspect`
  itself prints what its own list says, whatever `redact:` claims.

  The derive compiles into a protocol implementation module,
  `Inspect.<Struct>`, whose `inspect/2` reads the struct's fields at run
  time and keeps the ones a guard admits (Elixir 1.18 and 1.19 alike):

      inspect/2:
        {:move, {:atom, :struct}, {:x, 0}}
        {:call_ext, 1, {:extfunc, Struct, :__info__, 1}}
        {:make_fun3, {Inspect.Struct, :"-inspect/2-fun-0-", 2}, ...}
        {:call_ext, 3, {:extfunc, Enum, :reduce, 3}}
        ...
        {:call_ext_last, 4, {:extfunc, Inspect.Any, :inspect, 4}, 3}

      -inspect/2-fun-0-/2:
        {:get_map_elements, _, {:x, 0}, {:list, [atom: :field, x: 2]}}
        {:select_val, {:x, 2}, _, {:list, [atom: :id, f: 23, atom: :name, f: 23]}}

  Both options compile to the same guard over the fields that remain
  (`except:` has already been subtracted, `only:` already intersected),
  so the atoms the field is compared against are exactly the fields
  `inspect/1` shows: one `is_eq_exact` for a single field, a `select_val`
  for more, and no comparison at all for `only: []`, whose filter
  compiles away. `optional:` adds a default check after the guard and
  compares no atoms with the field.

  A module is recognised as a derived implementation only by that
  shape — the `__info__(:struct)` call on the struct it is named for and
  the hand-off to `Inspect.Any` or `Inspect.Map` — so a hand-written
  `defimpl Inspect` yields nothing, and the struct keeps the reading it
  had without one.

  ## Emitted facts

  - `inspect_derived(mod)` — `mod`'s `Inspect` is derived
  - `inspect_shows(mod, field)` — and prints `field`
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Instr, only: [register: 1]

  # Where the derived inspect/2 hands the kept fields over: Inspect.Map
  # when nothing is filtered, Inspect.Any otherwise; `inspect/4` through
  # Elixir 1.18, `inspect_as_struct/4` from 1.19.
  @renderers for m <- [Inspect.Any, Inspect.Map],
                 f <- [:inspect, :inspect_as_struct],
                 do: {m, f, 4}

  @impl true
  def relations, do: [:inspect_derived, :inspect_shows]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    with "Elixir.Inspect." <> _ <- Atom.to_string(mod),
         {:ok, target} <- derived_target(mod, functions) do
      target_str = inspect(target)

      functions
      |> Enum.filter(&filter_function?/1)
      |> Enum.flat_map(fn {:function, _, _, _, instrs} -> shown_fields(instrs) end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce(add_fact(%{}, :inspect_derived, [target_str]), fn field, facts ->
        add_fact(facts, :inspect_shows, [target_str, inspect(field)])
      end)
    else
      _ -> %{}
    end
  end

  # The struct whose fields inspect/2 reads, when inspect/2 is the
  # derived one and the module is named for that struct.
  defp derived_target(mod, functions) do
    case Enum.find(functions, &match?({:function, :inspect, 2, _, _}, &1)) do
      {:function, _, _, _, instrs} ->
        calls = Enum.flat_map(instrs, &external_call/1)
        target = struct_info_target(instrs)

        if target != nil and Module.concat(Inspect, target) == mod and
             Enum.any?(calls, &(&1 in @renderers)) do
          {:ok, target}
        else
          :error
        end

      nil ->
        :error
    end
  end

  # `Struct.__info__(:struct)`: the argument is moved into {x,0} right
  # before the call.
  defp struct_info_target(instrs) do
    instrs
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      [{:move, {:atom, :struct}, {:x, 0}}, {:line, _}, call] -> info_call(call)
      [{:move, {:atom, :struct}, {:x, 0}}, call, _] -> info_call(call)
      _ -> nil
    end)
  end

  defp info_call(call) do
    case external_call(call) do
      [{target, :__info__, 1}] -> target
      _ -> nil
    end
  end

  defp external_call({:call_ext, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  defp external_call({:call_ext_last, _, {:extfunc, m, f, a}, _}), do: [{m, f, a}]
  defp external_call({:call_ext_only, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  defp external_call(_), do: []

  # The comprehension's filter lives in a function the compiler names
  # after inspect/2: the fun handed to Enum.reduce, or a list
  # comprehension's own recursion.
  defp filter_function?({:function, name, _, _, _}),
    do: String.starts_with?(Atom.to_string(name), "-inspect/2-")

  # Every atom the field is compared against. The register holding the
  # field is the one `%{field: field}` loads it into.
  defp shown_fields(instrs) do
    registers =
      Enum.flat_map(instrs, fn
        {:get_map_elements, _fail, _src, {:list, pairs}} -> field_registers(pairs)
        _ -> []
      end)

    Enum.flat_map(instrs, fn
      {:select_val, reg, _fail, {:list, cases}} ->
        if register(reg) in registers, do: case_atoms(cases), else: []

      {:test, op, _fail, [a, {:atom, field}]} when op in [:is_eq_exact, :is_ne_exact] ->
        if register(a) in registers, do: [field], else: []

      _ ->
        []
    end)
  end

  defp field_registers([{:atom, :field}, reg | _rest]), do: [register(reg)]
  defp field_registers([_key, _reg | rest]), do: field_registers(rest)
  defp field_registers(_), do: []

  defp case_atoms([{:atom, value}, _label | rest]), do: [value | case_atoms(rest)]
  defp case_atoms([_value, _label | rest]), do: case_atoms(rest)
  defp case_atoms(_), do: []
end
