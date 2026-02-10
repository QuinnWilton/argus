defmodule Argus.Extractors.PhoenixSecurity do
  @moduledoc """
  Phoenix/Plug security extractor.

  Detects security-relevant patterns in Phoenix web applications: plug
  pipelines, controller actions, raw SQL queries, and redirect calls.
  These patterns are visible in compiled bytecode through module attributes
  and remote call patterns.

  ## Emitted facts

  - `plug_pipeline(mod, plug_mod, position)` — plug in a module's pipeline
  - `controller_action(mod, action, arity)` — Phoenix controller action function
  - `raw_sql_call(id, func, api)` — raw SQL query call
  - `redirect_call(id, func, target_type)` — Phoenix redirect with target origin
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, get_behaviours: 1, match_remote_call: 1, resolve_register: 3]

  alias Argus.Normalize

  # Raw SQL APIs.
  @raw_sql_apis [
    {Ecto.Adapters.SQL, :query, 2},
    {Ecto.Adapters.SQL, :query, 3},
    {Ecto.Adapters.SQL, :query, 4},
    {Ecto.Adapters.SQL, :query!, 2},
    {Ecto.Adapters.SQL, :query!, 3},
    {Ecto.Adapters.SQL, :query!, 4},
    {:epgsql, :squery, 2},
    {:epgsql, :equery, 3},
    {:epgsql, :equery, 4},
    {Postgrex, :query, 2},
    {Postgrex, :query, 3},
    {Postgrex, :query, 4},
    {Postgrex, :query!, 2},
    {Postgrex, :query!, 3},
    {Postgrex, :query!, 4},
    {MyXQL, :query, 2},
    {MyXQL, :query, 3},
    {MyXQL, :query, 4}
  ]

  # Standard controller action names in Phoenix.
  @action_names MapSet.new([
                  :index,
                  :show,
                  :new,
                  :create,
                  :edit,
                  :update,
                  :delete
                ])

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    attrs = module_data.attributes
    functions = module_data.functions

    facts = %{}

    # Extract plug pipeline from module attributes.
    facts = extract_plugs(facts, mod_str, attrs)

    # Detect controller actions and scan for security-relevant calls.
    facts = extract_controller_actions(facts, mod_str, attrs, functions)

    # Scan all functions for raw SQL and redirect calls.
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = Normalize.func_id(mod, name, arity)
      scan_security_calls(acc, func_id, instrs)
    end)
  end

  # Extract plugs from module attributes. Phoenix stores plug pipeline info
  # in @phoenix_plugs or @plugs attributes.
  defp extract_plugs(facts, mod_str, attrs) do
    plugs =
      Keyword.get_values(attrs, :plug) ++
        Keyword.get_values(attrs, :phoenix_plugs)

    plugs
    |> List.flatten()
    |> Enum.with_index()
    |> Enum.reduce(facts, fn
      {{plug_mod, _, _}, idx}, acc when is_atom(plug_mod) ->
        add_fact(acc, :plug_pipeline, [mod_str, inspect(plug_mod), to_string(idx)])

      {plug_mod, idx}, acc when is_atom(plug_mod) ->
        add_fact(acc, :plug_pipeline, [mod_str, inspect(plug_mod), to_string(idx)])

      _, acc ->
        acc
    end)
  end

  # Detect Phoenix controller actions. A module is a controller if it uses
  # Phoenix.Controller (check for known behaviours or attributes).
  defp extract_controller_actions(facts, mod_str, attrs, functions) do
    behaviours = get_behaviours(attrs)

    # Check if this looks like a Phoenix controller — uses Phoenix.Controller
    # as a behaviour or has phoenix-specific attributes.
    is_controller? =
      Enum.any?(behaviours, fn b ->
        b_str = inspect(b)
        String.contains?(b_str, "Controller") or String.contains?(b_str, "Phoenix")
      end) or
        Keyword.has_key?(attrs, :phoenix_controller) or
        has_action_fallback?(attrs)

    if is_controller? do
      Enum.reduce(functions, facts, fn {:function, name, arity, _entry, _instrs}, acc ->
        if name in @action_names or (arity == 2 and is_public_action?(name)) do
          add_fact(acc, :controller_action, [mod_str, to_string(name), to_string(arity)])
        else
          acc
        end
      end)
    else
      # Even without explicit controller detection, exported 2-arity functions
      # matching action names are likely controller actions.
      Enum.reduce(functions, facts, fn
        {:function, name, 2, _entry, _instrs}, acc ->
          if name in @action_names do
            add_fact(acc, :controller_action, [mod_str, to_string(name), "2"])
          else
            acc
          end

        {:function, _name, _arity, _entry, _instrs}, acc ->
          acc
      end)
    end
  end

  defp has_action_fallback?(attrs) do
    Keyword.has_key?(attrs, :action_fallback) or
      Keyword.has_key?(attrs, :phoenix_fallback)
  end

  # Check if a function name looks like a custom action (not starting with __).
  defp is_public_action?(name) do
    name_str = to_string(name)
    not String.starts_with?(name_str, "__") and not String.starts_with?(name_str, "-")
  end

  defp scan_security_calls(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        {:ok, mod, func, arity} ->
          id = "#{func_id}##{idx}"

          acc
          |> maybe_raw_sql(id, func_id, mod, func, arity)
          |> maybe_redirect(id, func_id, mod, func, arity, instrs, idx)

        :none ->
          acc
      end
    end)
  end

  defp maybe_raw_sql(facts, id, func_id, mod, func, arity) do
    if {mod, func, arity} in @raw_sql_apis do
      api = "#{inspect(mod)}.#{func}/#{arity}"
      add_fact(facts, :raw_sql_call, [id, func_id, api])
    else
      facts
    end
  end

  # Phoenix.Controller.redirect/2 detection.
  defp maybe_redirect(facts, id, func_id, Phoenix.Controller, :redirect, 2, instrs, idx) do
    target_type = resolve_redirect_target(instrs, idx)
    add_fact(facts, :redirect_call, [id, func_id, target_type])
  end

  defp maybe_redirect(facts, _id, _func_id, _mod, _func, _arity, _instrs, _idx), do: facts

  # Resolve whether the redirect target is static or dynamic.
  # The options (x1) contain either `to:` (internal) or `external:` (external).
  defp resolve_redirect_target(instrs, idx) do
    case resolve_register(instrs, idx, {:x, 1}) do
      {:ok, opts} when is_list(opts) ->
        cond do
          Keyword.has_key?(opts, :to) -> "static"
          Keyword.has_key?(opts, :external) -> "dynamic"
          true -> "dynamic"
        end

      _ ->
        "dynamic"
    end
  end
end
