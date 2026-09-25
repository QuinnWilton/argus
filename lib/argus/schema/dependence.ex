defmodule Argus.Schema.Dependence do
  @moduledoc """
  What decides or feeds a call, a shared-state operation or a return
  (`Argus.Extractors.Dependence`).

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
      %{
        name: :site_depends,
        layer: 2,
        fields: [
          {:site, :instr_id,
           "a shared-state operation: a name lookup, claim or release, an ETS or dirty Mnesia op"},
          {:func, :func_id, "the function containing it"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol,
           "the parameter's position, the callee's function ID, or the shared-state operation's instruction ID"}
        ],
        doc: """
        The operation runs only because of a test on the source, or is handed \
        a value made from it (Argus.Extractors.Dependence). A site source is \
        another shared-state operation's result: the check a check-then-act \
        acts on.
        """
      },
      %{
        name: :call_decided,
        layer: 2,
        fields: [
          {:caller, :func_id, "the calling function"},
          {:callee, :func_id, "the callee, or a closure the caller builds"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        Some call to the callee runs only because of a test on the source: \
        everything the callee does is decided by it. Building a closure \
        counts as a call to it. Function-level.
        """
      },
      %{
        name: :call_arg_depends,
        layer: 2,
        fields: [
          {:caller, :func_id, "the calling function"},
          {:callee, :func_id, "the callee, or a closure the caller builds"},
          {:arg_pos, :number,
           "0-based argument position, or the closure's environment parameter"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        At some call to the callee, the argument depends on the source: made \
        from it, or computed under a test on it. Unlike call_arg_derived, \
        control counts, and the sources include call results. Function-level.
        """
      },
      %{
        name: :returns_depends,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        What the function returns depends on the source: a lookup helper \
        returns its site, a wrapper the call it makes, an identity function \
        its parameter.
        """
      },
      %{
        name: :returns_reads,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        returns_depends by data alone: the returned value is made from the \
        source, not merely chosen under a test on it. A getter that answers \
        what a lookup found returns the lookup; one that answers :ok or an \
        error on what it found returns neither.
        """
      },
      %{
        name: :site_reads,
        layer: 2,
        fields: [
          {:site, :instr_id, "a shared-state operation, as site_depends"},
          {:func, :func_id, "the function containing it"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        site_depends by data alone: the operation's arguments are made from \
        the source, not merely computed under a test on it. An insert whose \
        object carries what a lookup returned writes the read back; one that \
        only runs because of the lookup writes something else.
        """
      },
      %{
        name: :call_arg_reads,
        layer: 2,
        fields: [
          {:caller, :func_id, "the calling function"},
          {:callee, :func_id, "the callee"},
          {:arg_pos, :number, "0-based argument position"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        call_arg_depends by data alone, for calls (not closures): the argument \
        is made from the source. Function-level.
        """
      },
      %{
        name: :field_decides,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"},
          {:pos, :number,
           "the tuple element tested, from 0: an ETS row's key is 0, a Mnesia record's 1"}
        ],
        doc: """
        A test in the function decides on element `pos` of a tuple the source \
        holds, or on something made from it: `[{^k, cur}] when cur >= serial` \
        tests element 1 of the lookup's row. A test of the source's shape \
        alone — whether a lookup found a row — is not one; comparing the \
        row's key is one at the key's position. An `:ets.lookup_element/3` \
        answer is element 1 of its row. Function-level.
        """
      },
      %{
        name: :field_compared,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"},
          {:pos, :number, "the tuple element tested, as field_decides"},
          {:other_kind, :symbol, "param | call | site"},
          {:other_source, :symbol, "as site_depends"}
        ],
        doc: """
        A test in the function compares element `pos` of a tuple the source \
        holds with a value made from the other source, by data alone: \
        `[{^k, cur}] when cur >= serial` compares element 1 of the lookup's \
        row with parameter 1, and element 0 with parameter 0. A comparison \
        with a value nothing in the facts names (a clock read) has no row. \
        Function-level.
        """
      },
      %{
        name: :effect_decided,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        A message send, or a call into the runtime that changes something \
        outside the function (Argus.Purity.Effects: a process, a port, a \
        file, the network, a node; not logging), runs only because of a test \
        on the source. Project calls are call_decided's. Function-level.
        """
      }
    ])
  end
end
