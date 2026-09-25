defmodule Argus.Test.Fixtures.Consistency do
  @moduledoc """
  Fixtures for `failure`'s consistency rule: a call site that breaks with
  how the program's other sites treat the same callee.

  `DynamicSupervisor.start_child/2` and `GenServer.call/2` stand in for
  any process API. The counts are the point: three agreeing sites make a
  belief, and a deviant must be a quarter or fewer of the population.
  """

  defmodule DeviantIgnore do
    @moduledoc "Five sites match start_child's result; one discards it."
    def a(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def b(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def c(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def d(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def e(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))

    def f(_sup, spec) do
      DynamicSupervisor.start_child(:workers, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule DeviantBare do
    @moduledoc """
    A GenServer's client API: four functions guard GenServer.call on the
    pid they are handed with a try; one calls it bare. The target is the
    function's own parameter, in a module that runs a process loop: the
    module's processes.
    """
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    def a(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def b(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def c(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def d(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def e(s), do: GenServer.call(s, :ping)
  end

  defmodule WeakBelief do
    @moduledoc "Two sites check, one ignores: not enough agreement to call it a convention."
    def a(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def b(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))

    def c(_sup, spec) do
      DynamicSupervisor.start_child(:workers, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule NoMajority do
    @moduledoc "Three check, three ignore: a convention either way."
    def a(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def b(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def c(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))

    def d(_sup, spec) do
      DynamicSupervisor.start_child(:workers, spec)
      :ok
    end

    def e(_sup, spec) do
      DynamicSupervisor.start_child(:workers, spec)
      :ok
    end

    def f(_sup, spec) do
      DynamicSupervisor.start_child(:workers, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule OutsideScope do
    @moduledoc "File.write is not a process API: five checked and one ignored say nothing here."
    def a(_p, d), do: check(File.write("out.log", d))
    def b(_p, d), do: check(File.write("out.log", d))
    def c(_p, d), do: check(File.write("out.log", d))
    def d(_p, d), do: check(File.write("out.log", d))
    def e(_p, d), do: check(File.write("out.log", d))

    def f(_p, d) do
      File.write("out.log", d)
      :ok
    end

    defp check(:ok), do: :ok
    defp check({:error, _}), do: :error
  end

  defmodule TailReturns do
    @moduledoc "Sites that return the result hand the question to their callers; they are not deviants."
    def a(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def b(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def c(_sup, spec), do: check(DynamicSupervisor.start_child(:workers, spec))
    def d(_sup, spec), do: DynamicSupervisor.start_child(:workers, spec)
    def e(_sup, spec), do: DynamicSupervisor.start_child(:workers, spec)

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule TotalCallee do
    @moduledoc """
    Five sites keep :ets.new's table, one discards it: :ets.new/2's spec
    names no failure value (it returns the table or raises), so the
    discarded one has nothing to miss.
    """
    def a(_n), do: keep(:ets.new(:total, []))
    def b(_n), do: keep(:ets.new(:total, []))
    def c(_n), do: keep(:ets.new(:total, []))
    def d(_n), do: keep(:ets.new(:total, []))
    def e(_n), do: keep(:ets.new(:total, []))

    def f(_n) do
      :ets.new(:total, [:named_table])
      :ok
    end

    defp keep(t) when is_reference(t) or is_atom(t), do: {:table, t}
  end

  defmodule PerTarget do
    @moduledoc """
    Four sites read :gvar under a catch; one reads :stats bare, the only
    site on that table. mnesia's own shape (mnesia_lib:read_counter/1):
    each table keeps its own convention, and the bare read is not a
    deviant from the other table's. The four guarded reads are four
    call sites, as in SameTargetBare: pooled with :stats, they would be
    four against one.
    """
    def a(k), do: gvar(k)
    def b(k), do: gvar2(k)
    def c(k), do: gvar3(k)
    def d(k), do: gvar4(k)

    def e(k), do: :ets.lookup_element(:stats, k, 2)

    defp gvar(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp gvar2(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp gvar3(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp gvar4(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end
  end

  defmodule SameTargetBare do
    @moduledoc "Four sites read :gvar under a catch and a fifth reads it bare: the deviant."
    def a(k), do: guarded(k)
    def b(k), do: guarded2(k)
    def c(k), do: guarded3(k)
    def d(k), do: guarded4(k)
    def e(k), do: :ets.lookup_element(:gvar, k, 2)

    defp guarded(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp guarded2(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp guarded3(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp guarded4(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end
  end

  defmodule UnknownTargetBare do
    @moduledoc """
    The bare site's table is a parameter: its target is not known, and
    the four guarded sites on :gvar say nothing of whatever table it is.
    """
    def a(k), do: guarded(k)
    def b(k), do: guarded2(k)
    def c(k), do: guarded3(k)
    def d(k), do: guarded4(k)
    def e(t, k), do: :ets.lookup_element(t, k, 2)

    defp guarded(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp guarded2(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp guarded3(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end

    defp guarded4(k) do
      :ets.lookup_element(:gvar, k, 2)
    catch
      :error, :badarg -> nil
    end
  end

  defmodule OtherTable do
    @moduledoc "Guarded reads of another table: not part of :gvar's population."
    def a(k), do: other(k)
    def b(k), do: other(k)
    def c(k), do: other(k)

    defp other(k) do
      :ets.lookup_element(:other, k, 2)
    catch
      :error, :badarg -> nil
    end
  end

  defmodule StopMacro do
    @moduledoc "A library's `use` that writes a bare GenServer.stop into the module using it."
    defmacro __using__(_opts) do
      quote do
        def stop(_server), do: GenServer.stop(:worker)
      end
    end
  end

  defmodule GeneratedBare do
    @moduledoc """
    Four sites guard GenServer.stop; the fifth, bare, is the one `use
    StopMacro` wrote. It is the library's site, not the program's: no
    deviant (supavisor's `use Ecto.Repo` wrote Supavisor.Repo.stop/1).
    """
    use Argus.Test.Fixtures.Consistency.StopMacro

    def a(_s), do: guarded()
    def b(_s), do: guarded2()
    def c(_s), do: guarded3()
    def d(_s), do: guarded4()

    defp guarded do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end

    defp guarded2 do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end

    defp guarded3 do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end

    defp guarded4 do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end
  end

  defmodule WrittenBare do
    @moduledoc "The same five sites, the bare one written by hand: the deviant."
    def stop(_server), do: GenServer.stop(:worker)

    def a(_s), do: guarded()
    def b(_s), do: guarded2()
    def c(_s), do: guarded3()
    def d(_s), do: guarded4()

    defp guarded do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end

    defp guarded2 do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end

    defp guarded3 do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end

    defp guarded4 do
      GenServer.stop(:worker)
    catch
      :exit, _ -> :ok
    end
  end

  defmodule StartIgnored do
    @moduledoc """
    Five sites match GenServer.start_link's result; one discards it.
    startup.ignored_start_result reports that site, so the consistency
    rule does not report it again.
    """
    def a(_m), do: check(GenServer.start_link(Argus.Test.Fixtures.Consistency.Worker, :ok, []))
    def b(_m), do: check(GenServer.start_link(Argus.Test.Fixtures.Consistency.Worker, :ok, []))
    def c(_m), do: check(GenServer.start_link(Argus.Test.Fixtures.Consistency.Worker, :ok, []))
    def d(_m), do: check(GenServer.start_link(Argus.Test.Fixtures.Consistency.Worker, :ok, []))
    def e(_m), do: check(GenServer.start_link(Argus.Test.Fixtures.Consistency.Worker, :ok, []))

    def f(_m) do
      GenServer.start_link(Argus.Test.Fixtures.Consistency.Worker, :ok, [])
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule AfterOnly do
    @moduledoc """
    Three sites call update_counter inside a try with only an `after`,
    one bare. An `after` takes nothing: no site guards the call, and
    there is no belief to break.
    """
    def a(k) do
      :ets.update_counter(:after_only, k, 1)
    after
      send(self(), :done)
    end

    def b(k) do
      :ets.update_counter(:after_only, k, 2)
    after
      send(self(), :done)
    end

    def c(k) do
      :ets.update_counter(:after_only, k, 3)
    after
      send(self(), :done)
    end

    def d(k), do: :ets.update_counter(:after_only, k, 4)
  end

  defmodule WrongClass do
    @moduledoc """
    Three sites wrap update_counter in `catch :exit` and one is bare. The
    call fails with an error (badarg), which `catch :exit` does not take,
    so these guard nothing either; a rescue that only re-raises is the
    same.
    """
    def a(k) do
      :ets.update_counter(:wrong_class, k, 1)
    catch
      :exit, _ -> 0
    end

    def b(k) do
      :ets.update_counter(:wrong_class, k, 2)
    catch
      :exit, _ -> 0
    end

    def c(k) do
      :ets.update_counter(:wrong_class, k, 3)
    rescue
      e -> reraise e, __STACKTRACE__
    end

    def d(k), do: :ets.update_counter(:wrong_class, k, 4)
  end

  defmodule HiddenDeviant do
    @moduledoc """
    Three sites rescue update_counter's ArgumentError; the fourth sits in
    a try with only an `after`, which lets the badarg through. It is the
    deviant, as a bare call would be.
    """
    def a(k) do
      :ets.update_counter(:hidden, k, 1)
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      :ets.update_counter(:hidden, k, 2)
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      :ets.update_counter(:hidden, k, 3)
    rescue
      ArgumentError -> 0
    end

    def d(k) do
      :ets.update_counter(:hidden, k, 4)
    after
      send(self(), :bumped)
    end
  end

  defmodule WrongClassDeviant do
    @moduledoc """
    Three sites rescue update_counter's ArgumentError; the fourth sits in
    a try that catches only :exit, which lets the badarg through.
    """
    def a(k) do
      :ets.update_counter(:wrong_class_deviant, k, 1)
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      :ets.update_counter(:wrong_class_deviant, k, 2)
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      :ets.update_counter(:wrong_class_deviant, k, 3)
    rescue
      ArgumentError -> 0
    end

    def d(k) do
      :ets.update_counter(:wrong_class_deviant, k, 4)
    catch
      :exit, _ -> 0
    end
  end

  defmodule CallersWrongClass do
    @moduledoc """
    Three sites rescue update_counter's ArgumentError; the fourth is in a
    private helper whose only caller calls it inside a try that catches
    only :exit. A try stands on every way in, and none takes the error.
    """
    def a(k) do
      :ets.update_counter(:callers_wrong_class, k, 1)
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      :ets.update_counter(:callers_wrong_class, k, 2)
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      :ets.update_counter(:callers_wrong_class, k, 3)
    rescue
      ArgumentError -> 0
    end

    def d(k) do
      {:ok, bump(k)}
    catch
      :exit, _ -> 0
    end

    defp bump(k), do: :ets.update_counter(:callers_wrong_class, k, 4)
  end

  defmodule CallerGuards do
    @moduledoc """
    Three sites rescue update_counter's ArgumentError in their own
    function. The fourth is in a private helper whose only caller calls
    it inside a try that rescues it, and the fifth in one reached through
    another helper under the same kind of try (db_connection's
    Holder.hash_holder/2, under maybe_disconnect/3's rescue): both are
    guarded, by their callers. The first helper tail-calls, and so hands
    its exception to the caller as it hands its result.
    """
    def a(k) do
      :ets.update_counter(:caller_guards, k, 1)
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      :ets.update_counter(:caller_guards, k, 2)
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      :ets.update_counter(:caller_guards, k, 3)
    rescue
      ArgumentError -> 0
    end

    def d(k) do
      bump(k)
    rescue
      ArgumentError -> 0
    end

    def e(k) do
      reason(k) || false
    rescue
      _ -> false
    end

    defp bump(k), do: :ets.update_counter(:caller_guards, k, 4)

    defp reason(k), do: hash(k) > 10

    defp hash(k) do
      n = :ets.update_counter(:caller_guards, k, 5)
      n * 2
    end
  end

  defmodule ClosureInTry do
    @moduledoc """
    Three sites rescue update_counter's ArgumentError; the fourth runs in
    a closure that Enum.each calls inside a try that rescues it, in the
    same process: guarded.
    """
    def a(k) do
      :ets.update_counter(:closure_in_try, k, 1)
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      :ets.update_counter(:closure_in_try, k, 2)
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      :ets.update_counter(:closure_in_try, k, 3)
    rescue
      ArgumentError -> 0
    end

    def d(ks) do
      Enum.each(ks, fn k -> :ets.update_counter(:closure_in_try, k, 4) end)
    rescue
      ArgumentError -> 0
    end
  end

  defmodule TaskInTry do
    @moduledoc """
    The same closure handed to Task.async inside the try runs in the
    task's process, where the rescue does not reach: still the deviant.
    """
    def a(k) do
      :ets.update_counter(:task_in_try, k, 1)
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      :ets.update_counter(:task_in_try, k, 2)
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      :ets.update_counter(:task_in_try, k, 3)
    rescue
      ArgumentError -> 0
    end

    def d(k) do
      Task.await(Task.async(fn -> :ets.update_counter(:task_in_try, k, 4) end))
    rescue
      ArgumentError -> 0
    end
  end

  defmodule HelperOutsideTry do
    @moduledoc """
    A private helper one caller calls inside a rescue and another calls
    bare: some way in is unguarded, and the helper's site is the deviant.
    """
    def a(k) do
      :ets.update_counter(:helper_outside, k, 1)
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      :ets.update_counter(:helper_outside, k, 2)
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      :ets.update_counter(:helper_outside, k, 3)
    rescue
      ArgumentError -> 0
    end

    def d(k) do
      bump(k)
    rescue
      ArgumentError -> 0
    end

    def e(k), do: {:ok, bump(k)}

    defp bump(k), do: :ets.update_counter(:helper_outside, k, 4)
  end

  defmodule GuardedByCallers do
    @moduledoc """
    Three private helpers call update_counter bare, each called only
    inside a rescue; a public function calls it bare. The belief is
    held by the callers' tries, and the evidence says so.
    """
    def a(k) do
      {:ok, bump1(k)}
    rescue
      ArgumentError -> 0
    end

    def b(k) do
      {:ok, bump2(k)}
    rescue
      ArgumentError -> 0
    end

    def c(k) do
      {:ok, bump3(k)}
    rescue
      ArgumentError -> 0
    end

    def d(k), do: {:ok, :ets.update_counter(:guarded_by_callers, k, 4)}

    defp bump1(k), do: :ets.update_counter(:guarded_by_callers, k, 1)
    defp bump2(k), do: :ets.update_counter(:guarded_by_callers, k, 2)
    defp bump3(k), do: :ets.update_counter(:guarded_by_callers, k, 3)
  end

  defmodule ClosureEscapes do
    @moduledoc """
    A closure called inside a rescue and also returned: whoever the
    caller hands it to may run it anywhere, so the try does not cover it.
    """
    def d(k) do
      f = fn -> :ets.update_counter(:closure_escapes, k, 4) end

      try do
        f.()
      rescue
        ArgumentError -> 0
      end

      f
    end
  end

  defmodule SequinLiteral do
    @moduledoc """
    sequin's shape with literal tables: two sites rescue update_counter
    on :metrics and one on :counts, and log/1 calls it bare on :log, the
    only site on that table. What the program does with :metrics and
    :counts is not a belief about :log: no finding.
    """
    def m1(k) do
      :ets.update_counter(:metrics, k, {2, 1})
    rescue
      ArgumentError -> :ets.insert(:metrics, {k, 1, 0})
    end

    def m2(k) do
      :ets.update_counter(:metrics, k, [{3, 1}])
    rescue
      ArgumentError -> :ets.insert(:metrics, {k, 0, 1})
    end

    def count(k) do
      :ets.update_counter(:counts, k, {2, 1})
    rescue
      ArgumentError -> :ets.insert(:counts, {k, 1})
    end

    def log(k) do
      _ = :ets.update_counter(:log, k, {2, 1})
      :ok
    end
  end

  defmodule ReraiseOnly do
    @moduledoc """
    Three sites rescue update_counter's error only to log it and raise
    it again (finch's HTTP2.Pool.request/5 shape): the exception still
    propagates, so they guard nothing, and the bare fourth breaks no
    belief.
    """
    def a(k) do
      :ets.update_counter(:reraise_only, k, 1)
    rescue
      e ->
        send(self(), {:failed, e})
        reraise e, __STACKTRACE__
    end

    def b(k) do
      :ets.update_counter(:reraise_only, k, 2)
    catch
      kind, reason ->
        send(self(), {:failed, reason})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    def c(k) do
      :ets.update_counter(:reraise_only, k, 3)
    rescue
      e in ErlangError -> reraise e.original, __STACKTRACE__
    end

    def d(k), do: :ets.update_counter(:reraise_only, k, 4)
  end

  defmodule OwnSplit do
    @moduledoc """
    postgrex's SCRAM.LockedCache: a guarded read of :own_split and a bare
    one, where the program knows the row is there, beside four guarded
    reads of two other tables. :own_split has shown how it is treated,
    one against one, and is judged by its own sites: no deviant.
    """
    def soft(k) do
      :ets.lookup_element(:own_split, k, 2)
    catch
      :error, :badarg -> nil
    end

    def hard(k), do: {:ok, :ets.lookup_element(:own_split, k, 2)}

    def p1(k) do
      :ets.lookup_element(:split_a, k, 2)
    rescue
      ArgumentError -> nil
    end

    def p2(k) do
      :ets.lookup_element(:split_a, k, 3)
    rescue
      ArgumentError -> nil
    end

    def p3(k) do
      :ets.lookup_element(:split_b, k, 2)
    rescue
      ArgumentError -> nil
    end

    def p4(k) do
      :ets.lookup_element(:split_b, k, 3)
    rescue
      ArgumentError -> nil
    end
  end

  defmodule TableMissing do
    @moduledoc """
    Three caches rescue :ets.delete/2 on their own tables, and a fourth
    deletes from its table bare after checking it exists (blockster's
    BuxMinter). delete fails when the table is missing, not the row:
    whether one table exists says nothing of another, so there is no
    belief across tables.
    """
    def a(k) do
      :ets.delete(:missing_a, k)
    rescue
      ArgumentError -> true
    end

    def b(k) do
      :ets.delete(:missing_b, k)
    rescue
      ArgumentError -> true
    end

    def c(k) do
      :ets.delete(:missing_c, k)
    rescue
      ArgumentError -> true
    end

    def d(k) do
      if :ets.whereis(:missing_d) != :undefined, do: :ets.delete(:missing_d, k)
      :ok
    end
  end

  defmodule OwnerDeletes do
    @moduledoc """
    hackney_manager's shape: the server creates a named public table in
    init/1 and, in its own callbacks, deletes rows bare; three client
    functions, run in their callers' processes, delete under a rescue.
    While the server runs its table is there, so its own deletes cannot
    fail and break no belief.
    """
    use GenServer

    @impl true
    def init(state) do
      :ets.new(:owned_refs, [:named_table, :public, :set])
      {:ok, state}
    end

    @impl true
    def handle_info({:done, ref}, state) do
      forget(ref)
      {:noreply, state}
    end

    defp forget(ref), do: :ets.delete(:owned_refs, ref)

    def cancel(ref) do
      :ets.delete(:owned_refs, ref)
    rescue
      ArgumentError -> :gone
    end

    def close(ref) do
      :ets.delete(:owned_refs, ref)
    rescue
      ArgumentError -> :gone
    end

    def abort(ref) do
      :ets.delete(:owned_refs, ref)
    rescue
      ArgumentError -> :gone
    end
  end

  defmodule ClientDeletes do
    @moduledoc """
    OwnerDeletes with the bare delete in a fourth client function: it runs
    in its caller's process, where the table can be gone. The deviant.
    """
    use GenServer

    @impl true
    def init(state) do
      :ets.new(:client_refs, [:named_table, :public, :set])
      {:ok, state}
    end

    def cancel(ref) do
      :ets.delete(:client_refs, ref)
    rescue
      ArgumentError -> :gone
    end

    def close(ref) do
      :ets.delete(:client_refs, ref)
    rescue
      ArgumentError -> :gone
    end

    def abort(ref) do
      :ets.delete(:client_refs, ref)
    rescue
      ArgumentError -> :gone
    end

    def drop(ref), do: :ets.delete(:client_refs, ref)
  end

  defmodule ViaClient do
    @moduledoc """
    Four calls to a server by the via name a helper builds: three catch
    the exit, the fourth does not. The name is built, not a literal, and
    every call on what via/1 builds is one population.
    """
    def a(id) do
      GenServer.call(via(id), :a)
    catch
      :exit, _ -> :error
    end

    def b(id) do
      GenServer.call(via(id), :b)
    catch
      :exit, _ -> :error
    end

    def c(id) do
      GenServer.call(via(id), :c)
    catch
      :exit, _ -> :error
    end

    def d(id), do: GenServer.call(via(id), :d)

    defp via(id), do: {:via, Registry, {Argus.Test.Fixtures.Consistency.Registry, id}}
  end

  defmodule LazyOwner do
    @moduledoc """
    OwnerDeletes' shape, with the table made only when a caller asks
    (`:setup`), not in init/1: until then a lookup in the owner raises,
    and three of its four lookups rescue that. The bare one is the
    deviant.
    """
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:setup, _from, state) do
      :ets.new(:lazy_t, [:named_table])
      {:reply, :ok, state}
    end

    def handle_call(:a, _from, state), do: {:reply, lookup(:a), state}
    def handle_call(:b, _from, state), do: {:reply, lookup2(:b), state}
    def handle_call(:c, _from, state), do: {:reply, lookup3(:c), state}
    def handle_call(:d, _from, state), do: {:reply, :ets.lookup(:lazy_t, :d), state}

    defp lookup(k) do
      :ets.lookup(:lazy_t, k)
    rescue
      ArgumentError -> []
    end

    defp lookup2(k) do
      :ets.lookup(:lazy_t, k)
    rescue
      ArgumentError -> []
    end

    defp lookup3(k) do
      :ets.lookup(:lazy_t, k)
    rescue
      ArgumentError -> []
    end
  end

  defmodule ConditionalSeed do
    @moduledoc """
    SeededRows' shape, with the row seeded only when an option asks: a
    start without it leaves the row missing, and the bare read raises.
    """
    use GenServer

    @impl true
    def init(opts) do
      :ets.new(:cond_seeded, [:named_table, :public, :set])
      if opts[:seed], do: :ets.insert(:cond_seeded, {:mode, :fast})
      {:ok, opts}
    end

    def a do
      :ets.lookup_element(:cond_seeded, :mode, 2)
    rescue
      ArgumentError -> :slow
    end

    def b do
      :ets.lookup_element(:cond_seeded, :mode, 2)
    rescue
      ArgumentError -> :slow
    end

    def c do
      :ets.lookup_element(:cond_seeded, :mode, 2)
    rescue
      ArgumentError -> :slow
    end

    def d, do: :ets.lookup_element(:cond_seeded, :mode, 2)
  end

  defmodule SeededRows do
    @moduledoc """
    inet_db's shape: the server seeds a row in init/1 and nothing removes
    it; three functions read rows callers name under a rescue, and one
    reads the seeded row bare. A row that is always there cannot be
    missing: no deviant.
    """
    use GenServer

    @impl true
    def init(state) do
      :ets.new(:seeded, [:named_table, :public, :set])
      :ets.insert(:seeded, {:methods, [:none]})
      {:ok, state}
    end

    def methods, do: :ets.lookup_element(:seeded, :methods, 2)

    def a(k) do
      :ets.lookup_element(:seeded, k, 2)
    rescue
      ArgumentError -> nil
    end

    def b(k) do
      :ets.lookup_element(:seeded, k, 2)
    rescue
      ArgumentError -> nil
    end

    def c(k) do
      :ets.lookup_element(:seeded, k, 2)
    rescue
      ArgumentError -> nil
    end
  end

  defmodule UnseededRows do
    @moduledoc "SeededRows, and a function that deletes the seeded row: the bare read can miss."
    use GenServer

    @impl true
    def init(state) do
      :ets.new(:unseeded, [:named_table, :public, :set])
      :ets.insert(:unseeded, {:methods, [:none]})
      {:ok, state}
    end

    def methods, do: :ets.lookup_element(:unseeded, :methods, 2)
    def reset, do: :ets.delete(:unseeded, :methods)

    def a(k) do
      :ets.lookup_element(:unseeded, k, 2)
    rescue
      ArgumentError -> nil
    end

    def b(k) do
      :ets.lookup_element(:unseeded, k, 2)
    rescue
      ArgumentError -> nil
    end

    def c(k) do
      :ets.lookup_element(:unseeded, k, 2)
    rescue
      ArgumentError -> nil
    end
  end

  defmodule RemoteSends do
    @moduledoc """
    A send to a name on another node never raises where it is made: three
    sites guard one anyway, and a fourth is bare. None can fail, so there
    is no belief to break.
    """
    def a(m) do
      send({:collector, :stats@host}, m)
    rescue
      ArgumentError -> :ok
    end

    def b(m) do
      send({:collector, :stats@host}, m)
    rescue
      ArgumentError -> :ok
    end

    def c(m) do
      send({:collector, :stats@host}, m)
    rescue
      ArgumentError -> :ok
    end

    def d(m), do: send({:collector, :stats@host}, m)
  end

  defmodule LocalSends do
    @moduledoc "The same to a local name, which raises when nothing holds it: the bare one is the deviant."
    def a(m) do
      send(:collector, m)
    rescue
      ArgumentError -> :ok
    end

    def b(m) do
      send(:collector, m)
    rescue
      ArgumentError -> :ok
    end

    def c(m) do
      send(:collector, m)
    rescue
      ArgumentError -> :ok
    end

    def d(m), do: send(:collector, m)
  end
end
