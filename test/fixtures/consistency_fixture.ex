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
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def c(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def d(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def e(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))

    def f(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule DeviantBare do
    @moduledoc "Four sites guard GenServer.call with a try; one calls it bare."

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
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))

    def c(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule NoMajority do
    @moduledoc "Three check, three ignore: a convention either way."
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def c(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))

    def d(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    def e(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    def f(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule OutsideScope do
    @moduledoc "File.write is not a process API: five checked and one ignored say nothing here."
    def a(p, d), do: check(File.write(p, d))
    def b(p, d), do: check(File.write(p, d))
    def c(p, d), do: check(File.write(p, d))
    def d(p, d), do: check(File.write(p, d))
    def e(p, d), do: check(File.write(p, d))

    def f(p, d) do
      File.write(p, d)
      :ok
    end

    defp check(:ok), do: :ok
    defp check({:error, _}), do: :error
  end

  defmodule TailReturns do
    @moduledoc "Sites that return the result hand the question to their callers; they are not deviants."
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def c(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def d(sup, spec), do: DynamicSupervisor.start_child(sup, spec)
    def e(sup, spec), do: DynamicSupervisor.start_child(sup, spec)

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule TotalCallee do
    @moduledoc """
    Five sites keep :ets.new's table, one discards it: :ets.new/2's spec
    names no failure value (it returns the table or raises), so the
    discarded one has nothing to miss.
    """
    def a(n), do: keep(:ets.new(n, []))
    def b(n), do: keep(:ets.new(n, []))
    def c(n), do: keep(:ets.new(n, []))
    def d(n), do: keep(:ets.new(n, []))
    def e(n), do: keep(:ets.new(n, []))

    def f(n) do
      :ets.new(n, [:named_table])
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
    The bare site's table is a parameter: it is judged against every site
    of the callee, the four guarded ones on :gvar included.
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
        def stop(server), do: GenServer.stop(server)
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

    def a(s), do: guarded(s)
    def b(s), do: guarded2(s)
    def c(s), do: guarded3(s)
    def d(s), do: guarded4(s)

    defp guarded(s) do
      GenServer.stop(s)
    catch
      :exit, _ -> :ok
    end

    defp guarded2(s) do
      GenServer.stop(s)
    catch
      :exit, _ -> :ok
    end

    defp guarded3(s) do
      GenServer.stop(s)
    catch
      :exit, _ -> :ok
    end

    defp guarded4(s) do
      GenServer.stop(s)
    catch
      :exit, _ -> :ok
    end
  end

  defmodule WrittenBare do
    @moduledoc "The same five sites, the bare one written by hand: the deviant."
    def stop(server), do: GenServer.stop(server)

    def a(s), do: guarded(s)
    def b(s), do: guarded2(s)
    def c(s), do: guarded3(s)
    def d(s), do: guarded4(s)

    defp guarded(s) do
      GenServer.stop(s)
    catch
      :exit, _ -> :ok
    end

    defp guarded2(s) do
      GenServer.stop(s)
    catch
      :exit, _ -> :ok
    end

    defp guarded3(s) do
      GenServer.stop(s)
    catch
      :exit, _ -> :ok
    end

    defp guarded4(s) do
      GenServer.stop(s)
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
    def a(m), do: check(GenServer.start_link(m, :ok, []))
    def b(m), do: check(GenServer.start_link(m, :ok, []))
    def c(m), do: check(GenServer.start_link(m, :ok, []))
    def d(m), do: check(GenServer.start_link(m, :ok, []))
    def e(m), do: check(GenServer.start_link(m, :ok, []))

    def f(m) do
      GenServer.start_link(m, :ok, [])
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
end
