defmodule Argus.Extractors.Ports do
  @moduledoc """
  Port creation extractor.

  A port is an OS-level resource (an external program, a driver, a file
  descriptor) owned by the process that opens it — and, like a linked
  process, it dies when that process terminates. Recording where ports are
  opened lets a consumer attribute them to the owning process in the
  supervision tree, the same way ETS tables are attributed.

  Detects the port-opening calls that appear as remote calls in bytecode:

    * `Port.open(name, settings)` / `:erlang.open_port(name, settings)` —
      the primitive; `name` carries the mechanism (`{:spawn, cmd}`,
      `{:spawn_executable, path}`, `{:spawn_driver, name}`, `{:fd, _, _}`).
      NOTE Elixir's `Port.open/2` compiles to `:erlang.open_port`, so both
      source forms surface with the `"erlang.open_port"` mechanism.
    * `System.cmd/2,3` and `System.shell/1,2` — run an external command
      through a spawned-executable port.
    * `:os.cmd/1,2` — the Erlang shell-out, also a port under the hood.

  ## Emitted facts

  - `port_open(id, func, mechanism, target)` — a port creation site: the
    mechanism (`"Port.open"`, `"System.cmd"`, …) and the resolved command /
    executable / driver, or `"dynamic"` when it isn't a compile-time literal
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, each_remote_call: 3, resolve_register: 3, track_dynamic: 5]

  @impl true
  def relations,
    do: [
      :port_open
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    each_remote_call(module_data, %{}, &handle_call/3)
  end

  # The `name` argument (x0) of Port.open/open_port carries the mechanism.
  defp handle_call(facts, ctx, {Port, :open, 2}),
    do: emit(facts, ctx, "Port.open", spawn_target(ctx))

  defp handle_call(facts, ctx, {:erlang, :open_port, 2}),
    do: emit(facts, ctx, "erlang.open_port", spawn_target(ctx))

  # System.cmd/System.shell/os.cmd take the command as their first argument.
  defp handle_call(facts, ctx, {System, :cmd, arity}) when arity in [2, 3],
    do: emit(facts, ctx, "System.cmd", command(ctx))

  defp handle_call(facts, ctx, {System, :shell, arity}) when arity in [1, 2],
    do: emit(facts, ctx, "System.shell", command(ctx))

  defp handle_call(facts, ctx, {:os, :cmd, arity}) when arity in [1, 2],
    do: emit(facts, ctx, "os.cmd", command(ctx))

  defp handle_call(facts, _ctx, _mfa), do: facts

  defp emit(facts, ctx, mechanism, target) do
    id = InstrId.mint(ctx.func_id, ctx.idx)

    facts
    |> track_dynamic(target, ctx, :port_target, :port_open)
    |> add_fact(:port_open, [id, ctx.func_id, mechanism, target])
  end

  # Port.open's name is a `{mechanism, spec}` tuple; the spec (the command,
  # the executable path, the driver name) is the interesting part.
  defp spawn_target(ctx) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, {kind, spec}} when kind in [:spawn, :spawn_executable, :spawn_driver] ->
        display(spec)

      {:ok, {:fd, _in, _out}} ->
        "fd"

      {:ok, other} ->
        display(other)

      _ ->
        "dynamic"
    end
  end

  defp command(ctx) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, value} -> display(value)
      _ -> "dynamic"
    end
  end

  # A command/path is a binary or charlist literal when static. Anything
  # else (a runtime-built string, or the `:dynamic` resolution placeholder
  # standing in for an unresolved tuple element) is honestly "dynamic".
  defp display(:dynamic), do: "dynamic"
  defp display(value) when is_binary(value), do: cap(value)
  defp display(value) when is_list(value), do: charlist_or_dynamic(value)
  defp display(value) when is_atom(value), do: inspect(value)
  defp display(_), do: "dynamic"

  defp charlist_or_dynamic(list) do
    if List.ascii_printable?(list), do: cap(List.to_string(list)), else: "dynamic"
  end

  # A shelled-out command can be an arbitrarily long inline script; keep the
  # fact (and the tree label) readable.
  defp cap(string) when byte_size(string) > 80, do: binary_part(string, 0, 79) <> "…"
  defp cap(string), do: string
end
