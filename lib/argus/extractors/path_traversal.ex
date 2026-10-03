defmodule Argus.Extractors.PathTraversal do
  @moduledoc """
  Upload callback filename fields reaching filesystem path arguments.

  A callback's metadata path and entry client_name have distinct identities. The
  latter is supplied by the client. Basename only protects a final file component;
  it never proves arbitrary path containment or directory-operation safety.
  """
  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.PathTraversal.Flow
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:upload_path_use, :upload_path_leaf_safe]

  @impl true
  def extract(data) do
    sites = CallSites.for_module(data)
    sources = upload_callbacks(sites)

    if MapSet.size(sources) == 0 do
      %{}
    else
      functions =
        Map.new(data.functions, fn {:function, name, arity, _, instrs} ->
          {InstrId.func_id(data.module, name, arity), instrs}
        end)

      sites
      |> Enum.reduce(%{}, fn site, facts ->
        ctx = %{
          func: site.func_id,
          instrs: site.instrs,
          sources: sources,
          functions: functions,
          args: %{}
        }

        {values, unknown?} =
          Enum.reduce(path_positions(site.mfa), {[], false}, fn {pos, leaf?}, {acc, uncertain?} ->
            {values, unknown?} = Flow.value(ctx, site.idx, {:x, pos})

            values =
              Enum.map(values, fn {source, joined, safe?} -> {source, joined, safe? and leaf?} end)

            {values ++ acc, unknown? or uncertain?}
          end)

        emit(facts, site, values, unknown?)
      end)
      |> Map.new(fn {relation, rows} -> {relation, Enum.sort(Enum.uniq(rows))} end)
    end
  end

  defp upload_callbacks(sites) do
    for %{mfa: {Phoenix.LiveView, :consume_uploaded_entries, 3}} = site <- sites,
        {kind, {mod, name, arity}} when kind in [:closure, :external] <-
          [Resolve.fun_origin(site.instrs, site.idx, {:x, 2})],
        into: MapSet.new(),
        do: InstrId.func_id(mod, name, arity)
  end

  # cp copies to a file, unlike cp_r; a directory destination fails. Keep both
  # argument positions because an attacker-controlled source can disclose a file.
  defp path_positions({File, fun, arity}) when fun in [:cp, :cp!] and arity in [2, 3],
    do: [{0, true}, {1, true}]

  defp path_positions({File, fun, arity}) when fun in [:write, :write!] and arity in [2, 3],
    do: [{0, true}]

  defp path_positions({File, fun, 1}) when fun in [:read, :read!, :rm, :rm!],
    do: [{0, true}]

  defp path_positions({File, fun, arity})
       when fun in [:cp_r, :cp_r!, :rename, :rename!] and arity in [2, 3],
       do: [{0, false}, {1, false}]

  defp path_positions({File, fun, 1})
       when fun in [:rm_rf, :rm_rf!, :rmdir, :rmdir!, :mkdir, :mkdir!, :mkdir_p, :mkdir_p!],
       do: [{0, false}]

  defp path_positions(_mfa), do: []

  defp emit(facts, site, values, unknown?) do
    id = InstrId.mint(site.func_id, site.idx)
    {mod, fun, arity} = site.mfa

    values
    |> Enum.group_by(fn {source, _, _} -> source end)
    |> Enum.sort()
    |> Enum.reduce(facts, fn {source, paths}, acc ->
      joined? = Enum.any?(paths, fn {_, joined, _} -> joined end)

      acc =
        add_fact(acc, :upload_path_use, [
          id,
          site.func_id,
          "#{inspect(mod)}.#{fun}/#{arity}",
          source,
          if(joined?, do: "joined", else: "filename")
        ])

      safe? = not unknown? and Enum.all?(paths, fn {_, _, bounded?} -> bounded? end)
      if safe?, do: add_fact(acc, :upload_path_leaf_safe, [id, site.func_id, source]), else: acc
    end)
  end
end
