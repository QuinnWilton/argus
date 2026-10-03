defmodule Argus.Extractors.HtmlInjection do
  @moduledoc """
  Raw HTML outputs with same-value, all-path escaping proofs.

  Proofs follow actual same-module helper returns and every direct caller of a
  private helper. Escaped closures and exported functions retain unknown callers.
  HTML text escaping applies only in text contexts. JavaScript string escaping
  additionally requires the matching quote, backslash and newline escaping in
  the correct order, and protection against closing the surrounding script tag.
  Unsupported HTML/JavaScript syntax and external rendering helpers remain
  unknown. Library and helper names alone never establish markup safety.

  Known limits: response recognition requires a literal HTML MIME type at a
  content-type setter on the same connection. A MIME type computed by a helper
  is not yet modeled. Parameter provenance follows actual same-module helper
  returns but not arbitrary returns from another module. Missing flow or missing
  escaping facts do not establish that such code is safe.

  Render assigns may contain safe generated SVG, finite messages, or intentional
  developer documentation. Proving one writer safe does not prove the complete
  update-to-render contract: caller-provided assigns, other writers and unknown
  configuration fields remain possible input. No helper name or assign key alone
  establishes trust.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.HtmlInjection.Proof
  alias Argus.Extractors.SecurityValues
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:html_output_site, :html_input_escaped]

  @impl true
  def extract(data) do
    sites =
      data
      |> CallSites.for_module()
      |> Enum.flat_map(fn site ->
        case output_position(site) do
          nil -> []
          pos -> [{site, pos}]
        end
      end)
      |> Enum.group_by(fn {site, _} -> site.func_id end)

    proofs = if map_size(sites) > 0, do: Proof.index(data)

    for {:function, name, arity, _, instrs} <- data.functions,
        func = InstrId.func_id(data.module, name, arity),
        Map.has_key?(sites, func),
        reduce: %{} do
      facts ->
        types = SecurityValues.html_binary_types(Helpers.cfg(data, name, arity), instrs)

        Enum.reduce(Map.fetch!(sites, func), facts, fn {site, pos}, acc ->
          id = InstrId.mint(func, site.idx)
          {mod, fun, arity} = site.mfa

          acc =
            add_fact(acc, :html_output_site, [
              id,
              func,
              "#{inspect(mod)}.#{fun}/#{arity}",
              to_string(pos)
            ])

          if SecurityValues.safe_at?(instrs, site.idx, {:x, pos}, "html_text", types) or
               Proof.safe_at?(proofs, func, site.idx, {:x, pos}),
             do: add_fact(acc, :html_input_escaped, [id, func, to_string(pos)]),
             else: acc
        end)
    end
    |> Map.new(fn {relation, rows} -> {relation, Enum.sort(Enum.uniq(rows))} end)
  end

  defp output_position(%{mfa: {Phoenix.HTML, :raw, 1}}), do: 0
  defp output_position(%{mfa: {Phoenix.Controller, :html, 2}}), do: 1

  defp output_position(%{mfa: {Plug.Conn, :send_resp, 3}} = site),
    do: if(html_connection?(site.instrs, site.idx), do: 2)

  defp output_position(_site), do: nil

  defp html_connection?(instrs, idx) do
    case Resolve.call_result_origin(instrs, idx, {:x, 0}) do
      {:ok, {Plug.Conn, :put_resp_content_type, arity}, at} when arity in [2, 3] ->
        html_type?(Resolve.resolve_register(instrs, at, {:x, 1}))

      {:ok, {Plug.Conn, :put_resp_header, 3}, at} ->
        Resolve.resolve_register(instrs, at, {:x, 1}) == {:ok, "content-type"} and
          html_type?(Resolve.resolve_register(instrs, at, {:x, 2}))

      _ ->
        false
    end
  end

  defp html_type?({:ok, value}) when is_binary(value) do
    type = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
    type in ["text/html", "application/xhtml+xml"]
  end

  defp html_type?(_), do: false
end
