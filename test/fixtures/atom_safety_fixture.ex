defmodule Argus.Test.Fixtures.UnsafeAtomCreation do
  @moduledoc false

  def to_atom_from_input(input), do: String.to_atom(input)
  def binary_to_atom(bin), do: :erlang.binary_to_atom(bin)
  def list_to_atom(list), do: :erlang.list_to_atom(list)
  def existing_atom(bin), do: String.to_existing_atom(bin)
end

defmodule Argus.Test.Fixtures.UnsafeDeserialization do
  @moduledoc false

  def decode_unsafe(bin), do: :erlang.binary_to_term(bin)
  # Named for what the option does, not for what it is often assumed to do.
  # `[:safe]` blocks new atoms and new EXTERNAL funs; a fun referencing an
  # already-loaded module passes, which is how Paginator CVE-2020-15150 was
  # RCE *through* this option.
  def decode_atoms_only(bin), do: :erlang.binary_to_term(bin, [:safe])

  # The one that actually clears: it walks the term and rejects executable
  # constructors rather than trusting an option.
  def decode_validated(bin), do: Plug.Crypto.non_executable_binary_to_term(bin, [:safe])
end

defmodule Argus.Test.Fixtures.CodeExecution do
  @moduledoc false

  def eval(code), do: Code.eval_string(code)
  def os_cmd(cmd), do: :os.cmd(cmd)
  def system_cmd(cmd, args), do: System.cmd(cmd, args)
  def static_system_cmd, do: System.cmd("echo", ["hello"])
  def static_command_dynamic_args(args), do: System.cmd("fwup", args)
  def static_command_no_args, do: System.cmd("free", [])
  def shell_with_dynamic_script(script), do: System.cmd("sh", ["-c", script])
end

defmodule Argus.Test.Fixtures.SafeModule do
  @moduledoc false

  def to_existing_atom(input), do: String.to_existing_atom(input)
  def safe_decode(bin), do: Plug.Crypto.non_executable_binary_to_term(bin, [:safe])
  def hello, do: :world
end

defmodule Argus.Test.Fixtures.ExportedSinkCaller do
  @moduledoc "A private sink no request reaches, one call below an exported function."

  def tag(input), do: to_tag(input)

  defp to_tag(input), do: String.to_atom(input)
end

defmodule Argus.Test.Fixtures.AtomSources do
  @moduledoc """
  Atom creation no request reaches, by where its argument comes from.
  What a caller of the program hands in reaches an atom through `input/1`
  (an exported function nothing here calls), through the closure `keys/1`
  runs on each element, and through `name/1`, an export the program also
  calls itself with a literal: its users can call it with anything.
  `env_level/0` and `cookie!/1` make atoms of the environment, which a
  caller naming the variable does not choose; the macro `field/1` makes
  one at compile time, of the code that uses it.
  """

  def input(name), do: String.to_atom(name)

  def keys(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)

  def env_level, do: String.to_atom(System.get_env("LOG_LEVEL") || "info")

  def cookie!(env), do: String.to_atom(System.get_env(env))

  defmacro field(name), do: String.to_atom("#{name}_field")

  def default_name, do: name("main")

  def name(id), do: String.to_atom("#{id}-pipeline")
end

defmodule Argus.Test.Fixtures.AtomBounds do
  @moduledoc """
  Atoms made of values a guard or a conversion bounds, each beside the
  twin that stays reported. encore's capriccio `play/2`: `n in 1..8`
  makes one of eight atoms, as does `is_integer(n) and n >= 1 and n <= 8`
  and a range tested in the body. An atom `is_atom/1` tested, or an
  atom's name read out of it, makes one atom per atom that exists.

  Reported: a range with no integer test (every float between its ends
  passes), a range with one end, a range too wide to bound anything, an
  atom beside an integer nothing bounds, a name no guard says is an
  atom, and an atom's name deserialized — a deserialization's question
  is what its bytes are, not how many there can be.
  """

  def phrase(n) when n in 1..8, do: String.to_atom("phrase_#{n}")

  def explicit(n) when is_integer(n) and n >= 1 and n <= 8, do: String.to_atom("p_#{n}")

  def within(n) do
    if n in 0..3, do: :erlang.list_to_atom(~c"p" ++ :erlang.integer_to_list(n)), else: :none
  end

  def suffixed(name) when is_atom(name), do: :"#{name}_id"

  def renamed(name), do: String.to_atom(Atom.to_string(name) <> "_sup")

  def renamed_list(name), do: :erlang.list_to_atom(:erlang.atom_to_list(name) ++ ~c"_sup")

  def between(n) when n >= 1 and n <= 8, do: String.to_atom("f_#{n}")

  def from(n) when is_integer(n) and n >= 1, do: String.to_atom("o_#{n}")

  def wide(n) when n in 1..100_000, do: String.to_atom("w_#{n}")

  def numbered(name, n) when is_atom(name) and is_integer(n), do: :"#{name}_#{n}"

  def named(name), do: :"#{name}_id"

  def decode(name) when is_atom(name), do: :erlang.binary_to_term(Atom.to_string(name))
end

defmodule Argus.Test.Fixtures.AtomFromMessages do
  @moduledoc "A server makes an atom of a message it is sent: the program's own data."
  use GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:rename, name}, state),
    do: {:noreply, Map.put(state, :name, String.to_atom(name))}
end

defmodule Argus.Test.Fixtures.AtomProcessName do
  @moduledoc "Broadway's process_name/2: the pipeline's own name, from its own configuration."
  @behaviour Broadway

  def process_name({:via, _module, {name, _id}}, base), do: String.to_atom("#{name}-#{base}")
end

defmodule Argus.Test.Fixtures.AtomCallerInput do
  @moduledoc """
  Atoms made of what a library's users hand in, three ways the walk from
  the sink must follow: through a call no propagator table lists
  (`Macro.underscore/1`), and through a client function that hands its
  argument to its server in a call's message, which handle_call/3 makes
  the atom of.
  """

  def key(name), do: String.to_atom(Macro.underscore(name))

  defmodule NameServer do
    @moduledoc "Interns the names its client API is handed."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def intern(name), do: GenServer.call(__MODULE__, {:intern, name})

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:intern, name}, _from, state), do: {:reply, String.to_atom(name), state}
  end
end
