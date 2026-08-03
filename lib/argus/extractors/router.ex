defmodule Argus.Extractors.Router do
  @moduledoc """
  The HTTP routes a Phoenix router declares.

  `Phoenix.Router` compiles `__routes__/0` to a single literal — one map per
  route, with `path`, `verb`, `plug` and `plug_opts`:

      %{path: "/public/health", plug: LivebookWeb.HealthController,
        plug_opts: :index, verb: :get, ...}

  Analyses that reach a request entry point can only say *reachable from a
  plug entry point* without this. With it they can say **reachable from
  `GET /public/sessions/:id/assets/...`**, which is the difference between a
  reader trusting a severity and going to check it themselves.

  `pipe_through` is deliberately absent: Phoenix compiles pipelines into the
  router's dispatch function as control flow rather than into this literal,
  so *is this route authenticated* is derivable but not from here. The path
  is often a good proxy — projects that segregate public routes do it by
  prefix — and that judgement belongs to whoever reads the finding.

  ## Emitted facts

  - `http_route(router, verb, path, plug, action)`
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    case Enum.find(functions, &match?({:function, :__routes__, 0, _, _}, &1)) do
      nil -> %{}
      {:function, _, _, _, instrs} -> emit(inspect(mod), routes(instrs))
    end
  end

  defp routes(instrs) do
    Enum.find_value(instrs, [], fn
      {:move, {:literal, list}, {:x, 0}} when is_list(list) -> list
      _ -> false
    end)
  end

  defp emit(router, routes) do
    for %{path: path, verb: verb, plug: plug} = route <- routes,
        is_binary(path) and is_atom(verb) and is_atom(plug),
        reduce: %{} do
      facts ->
        add_fact(facts, :http_route, [
          router,
          Atom.to_string(verb),
          path,
          inspect(plug),
          inspect(Map.get(route, :plug_opts))
        ])
    end
  end
end
