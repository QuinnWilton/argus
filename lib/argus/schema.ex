defmodule Argus.Schema do
  @moduledoc """
  Fact relation definitions for Argus analysis.

  Each relation describes a table of facts that Argus extracts from BEAM
  bytecode or domain extractors. Relations map directly to Souffle `.decl`
  declarations and `.facts` files.

  ## Layers

  - **Layer 1** — generic bytecode facts extracted from any BEAM module.
  - **Layer 2** — domain-specific facts from pluggable extractors.
  """

  @type field_type :: :symbol | :number
  @type field :: {atom(), field_type(), String.t()}

  @type relation :: %{
          name: atom(),
          layer: 1 | 2,
          fields: [field()],
          doc: String.t()
        }

  # Layer 1: Module-level facts.

  @module_info %{
    name: :module_info,
    layer: 1,
    fields: [
      {:mod, :symbol, "module name"},
      {:name, :symbol, "module name (repeated for queries)"}
    ],
    doc: "Module existence."
  }

  @function_def %{
    name: :function_def,
    layer: 1,
    fields: [
      {:func, :symbol, "function ID (mod:name/arity)"},
      {:mod, :symbol, "module name"},
      {:name, :symbol, "function name"},
      {:arity, :number, "function arity"},
      {:entry, :number, "entry label number"},
      {:exported, :number, "1 if exported, 0 if local"}
    ],
    doc: "Function definition within a module."
  }

  @import_ref %{
    name: :import_ref,
    layer: 1,
    fields: [
      {:mod, :symbol, "imported module"},
      {:name, :symbol, "imported function name"},
      {:arity, :number, "imported function arity"}
    ],
    doc: "External function referenced by the module."
  }

  @module_attribute %{
    name: :module_attribute,
    layer: 1,
    fields: [
      {:mod, :symbol, "module name"},
      {:key, :symbol, "attribute key"},
      {:val, :symbol, "attribute value (stringified)"}
    ],
    doc: "Module attribute key-value pair."
  }

  # Layer 1: Instruction-level facts.

  @instruction %{
    name: :instruction,
    layer: 1,
    fields: [
      {:id, :symbol, "unique instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:idx, :number, "instruction index within function"},
      {:op, :symbol, "opcode name"}
    ],
    doc: "Every instruction in every function."
  }

  @next %{
    name: :next,
    layer: 1,
    fields: [
      {:from, :symbol, "instruction ID"},
      {:to, :symbol, "next instruction ID (fallthrough)"}
    ],
    doc: "Sequential (fallthrough) instruction ordering."
  }

  # Layer 1: Register / data flow facts.

  @move %{
    name: :move,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:src, :symbol, "source operand"},
      {:dst, :symbol, "destination operand"}
    ],
    doc: "Data move from source to destination."
  }

  @def_rel %{
    name: :def,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:reg, :symbol, "defined register"}
    ],
    doc: "Register definition (write)."
  }

  @use_rel %{
    name: :use,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:reg, :symbol, "used register"}
    ],
    doc: "Register use (read)."
  }

  @literal_value %{
    name: :literal_value,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:reg, :symbol, "destination register"},
      {:val, :symbol, "literal value (stringified)"}
    ],
    doc: "Literal value loaded into a register."
  }

  # Layer 1: Control flow facts.

  @jump %{
    name: :jump,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:target, :number, "target label number"}
    ],
    doc: "Unconditional jump to a label."
  }

  @branch %{
    name: :branch,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:on_true, :number, "label if condition holds"},
      {:on_false, :number, "label if condition fails (0 = fallthrough)"}
    ],
    doc: "Conditional branch (test instructions)."
  }

  @label_at %{
    name: :label_at,
    layer: 1,
    fields: [
      {:label, :number, "label number"},
      {:id, :symbol, "instruction ID of the label"}
    ],
    doc: "Maps a label number to the instruction at that position."
  }

  @select_branch %{
    name: :select_branch,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:val, :symbol, "matched value (stringified)"},
      {:target, :number, "target label number"}
    ],
    doc: "One arm of a select_val or select_tuple_arity."
  }

  # Layer 1: Call facts.

  @local_call %{
    name: :local_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:target, :symbol, "target label or MFA string"},
      {:arity, :number, "call arity"}
    ],
    doc: "Call to a local (same-module) function by label or MFA."
  }

  @remote_call %{
    name: :remote_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:mod, :symbol, "target module"},
      {:func, :symbol, "target function"},
      {:arity, :number, "call arity"}
    ],
    doc: "Call to an external (remote) function."
  }

  @tail_call_rel %{
    name: :tail_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"}
    ],
    doc: "Marks an instruction as a tail call."
  }

  @bif_call %{
    name: :bif_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:mod, :symbol, "BIF module"},
      {:func, :symbol, "BIF function"},
      {:arity, :number, "BIF arity"},
      {:fail, :number, "failure label (0 = no fail)"}
    ],
    doc: "Built-in function call."
  }

  # Layer 1: BEAM-specific facts.

  @allocate %{
    name: :allocate,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:stack, :number, "stack words allocated"},
      {:live, :number, "live X registers"}
    ],
    doc: "Stack frame allocation."
  }

  @deallocate %{
    name: :deallocate,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:stack, :number, "stack words deallocated"}
    ],
    doc: "Stack frame deallocation."
  }

  @send_msg %{
    name: :send_msg,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"}
    ],
    doc: "Message send instruction."
  }

  @recv_start %{
    name: :recv_start,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:fail, :number, "failure label"}
    ],
    doc: "Start of a receive loop (loop_rec)."
  }

  @recv_end %{
    name: :recv_end,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"}
    ],
    doc: "End of a receive clause (remove_message)."
  }

  @spawn_call %{
    name: :spawn_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:mod, :symbol, "spawned module"},
      {:func, :symbol, "spawned function"},
      {:arity, :number, "spawned function arity"}
    ],
    doc: "Process spawn detected via erlang:spawn* calls."
  }

  @try_start %{
    name: :try_start,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:handler, :number, "handler label"}
    ],
    doc: "Start of a try block."
  }

  @try_end %{
    name: :try_end,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"}
    ],
    doc: "End of a try block."
  }

  @make_fun %{
    name: :make_fun,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:target, :number, "lambda body label"},
      {:num_free, :number, "number of captured variables"}
    ],
    doc: "Lambda/closure creation."
  }

  @bs_start %{
    name: :bs_start,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:fail, :number, "failure label"}
    ],
    doc: "Start of binary matching."
  }

  @line_info %{
    name: :line_info,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:line, :number, "source line number"}
    ],
    doc: "Source line number annotation."
  }

  # Layer 2: Supervision extractor facts.

  @supervisor %{
    name: :supervisor,
    layer: 2,
    fields: [
      {:mod, :symbol, "supervisor module"},
      {:strategy, :symbol, "restart strategy"}
    ],
    doc: "Module that implements the Supervisor behaviour."
  }

  @supervisor_child %{
    name: :supervisor_child,
    layer: 2,
    fields: [
      {:sup, :symbol, "supervisor module"},
      {:position, :number, "child start order"},
      {:child_mod, :symbol, "child module"},
      {:restart, :symbol, "restart type (permanent/transient/temporary)"},
      {:type, :symbol, "child type (worker/supervisor)"}
    ],
    doc: "Child specification within a supervisor."
  }

  @named_process %{
    name: :named_process,
    layer: 2,
    fields: [
      {:mod, :symbol, "module"},
      {:name, :symbol, "registered process name"}
    ],
    doc: "Named process registration detected in code."
  }

  @process_link %{
    name: :process_link,
    layer: 2,
    fields: [
      {:from_mod, :symbol, "linking module"},
      {:to_mod, :symbol, "linked module"}
    ],
    doc: "Process link between modules."
  }

  @process_monitor %{
    name: :process_monitor,
    layer: 2,
    fields: [
      {:from_mod, :symbol, "monitoring module"},
      {:to_mod, :symbol, "monitored module"}
    ],
    doc: "Process monitor between modules."
  }

  # Layer 2: OTP pattern extractor facts.

  @implements_behaviour %{
    name: :implements_behaviour,
    layer: 2,
    fields: [
      {:mod, :symbol, "implementing module"},
      {:behaviour, :symbol, "behaviour module"}
    ],
    doc: "Module implements a specific OTP behaviour."
  }

  @sync_call %{
    name: :sync_call,
    layer: 2,
    fields: [
      {:caller_func, :symbol, "calling function ID"},
      {:callee_mod, :symbol, "target GenServer module"}
    ],
    doc: "GenServer.call target detected in code."
  }

  @async_cast %{
    name: :async_cast,
    layer: 2,
    fields: [
      {:caller_func, :symbol, "calling function ID"},
      {:callee_mod, :symbol, "target GenServer module"}
    ],
    doc: "GenServer.cast target detected in code."
  }

  # All relations indexed by name.

  @layer_1_relations [
    @module_info,
    @function_def,
    @import_ref,
    @module_attribute,
    @instruction,
    @next,
    @move,
    @def_rel,
    @use_rel,
    @literal_value,
    @jump,
    @branch,
    @label_at,
    @select_branch,
    @local_call,
    @remote_call,
    @tail_call_rel,
    @bif_call,
    @allocate,
    @deallocate,
    @send_msg,
    @recv_start,
    @recv_end,
    @spawn_call,
    @try_start,
    @try_end,
    @make_fun,
    @bs_start,
    @line_info
  ]

  @layer_2_relations [
    @supervisor,
    @supervisor_child,
    @named_process,
    @process_link,
    @process_monitor,
    @implements_behaviour,
    @sync_call,
    @async_cast
  ]

  @all_relations @layer_1_relations ++ @layer_2_relations

  @relations_by_name Map.new(@all_relations, fn r -> {r.name, r} end)

  @doc """
  Returns all relation definitions.
  """
  @spec all() :: [relation()]
  def all, do: @all_relations

  @doc """
  Returns layer 1 (generic bytecode) relation definitions.
  """
  @spec layer_1() :: [relation()]
  def layer_1, do: @layer_1_relations

  @doc """
  Returns layer 2 (domain extractor) relation definitions.
  """
  @spec layer_2() :: [relation()]
  def layer_2, do: @layer_2_relations

  @doc """
  Looks up a relation by name.
  """
  @spec fetch(atom()) :: {:ok, relation()} | :error
  def fetch(name) do
    case @relations_by_name do
      %{^name => rel} -> {:ok, rel}
      _ -> :error
    end
  end

  @doc """
  Looks up a relation by name, raising if not found.
  """
  @spec fetch!(atom()) :: relation()
  def fetch!(name) do
    case fetch(name) do
      {:ok, rel} -> rel
      :error -> raise ArgumentError, "unknown relation: #{inspect(name)}"
    end
  end

  @doc """
  Returns the number of fields for a relation.
  """
  @spec arity(atom()) :: non_neg_integer()
  def arity(name) do
    fetch!(name) |> Map.fetch!(:fields) |> length()
  end

  @doc """
  Returns field names for a relation.
  """
  @spec field_names(atom()) :: [atom()]
  def field_names(name) do
    fetch!(name) |> Map.fetch!(:fields) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Returns the Souffle type declaration string for a relation.
  """
  @spec souffle_decl(atom()) :: String.t()
  def souffle_decl(name) do
    rel = fetch!(name)

    fields_str =
      rel.fields
      |> Enum.map(fn {fname, ftype, _doc} -> "#{fname}: #{ftype}" end)
      |> Enum.join(", ")

    ".decl #{name}(#{fields_str})"
  end

  @doc """
  Returns all relation names.
  """
  @spec names() :: [atom()]
  def names, do: Enum.map(@all_relations, & &1.name)
end
