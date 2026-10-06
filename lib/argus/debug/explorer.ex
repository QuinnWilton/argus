# Compile the Breeze view only when the consuming project opts into Breeze.
if Code.ensure_loaded?(Breeze.View) do
  defmodule Argus.Debug.Explorer do
    @moduledoc """
    Breeze terminal explorer for the bundles created by `Argus.Debug`.

    Launch with `mix argus.debug explore path/to/bundle` or `run!/1` from IEx.
    Browse relations, filter and page through tuples, inspect rule references,
    follow IDs to source, and select retained successful runs. Exploration is
    read-only; refresh after editing or solving the bundle in another terminal.
    """

    use Breeze.View
    import Breeze.Blocks

    alias Argus.Debug
    alias Argus.Debug.Explorer.Bundle

    @page_size 20
    @help """
    Explore an Argus debug bundle

    /          Search relations by name. Enter returns to the relation list.
    Enter      Open a relation, row's fields, or a rule's source excerpt.
    Tab        Move between the search, relation list, filter, and rows.
    f          Focus the exact row filter: column=value. Enter applies it.
    x          Clear the row filter.
    n / N      Next / previous page of matching rows (20 per page).
    d          Relation description, column definitions, and producers.
    r          Rule references; Enter opens the selected source excerpt.
    w          Return to rows.
    b          Bundle manifest: analysis, solver, priors, sources, producers.
    t          Retained runs; Enter selects an indexed run.
    R          Reload the bundle and follow its latest successful run.
    Escape     Close source/fields/help; on a narrow terminal, return to relations.
    q          Quit. In a text input, Escape first leaves the input.

    Arrow keys, j/k, PageUp/PageDown, Home/End navigate lists and source.
    In row fields, Enter follows a function/instruction ID to application source.
    Enter on other values opens their full text.

    Intermediate relations have definitions but may have no saved rows. Use the
    displayed solve command in another terminal to expose one, then press R.
    Missing files are errors; empty files are empty relations.

    Historical runs show their own saved columns and rule copies. Older bundles
    have metadata only for the latest run; unindexed runs cannot be selected.
    Source paths refer to the original application checkout, which may have moved
    or changed since capture. Source is an excerpt, not a captured source snapshot.
    """

    @doc "Run until the user quits, restoring the terminal on exit."
    @spec run!(Path.t()) :: :ok | {:error, term()}
    def run!(root) do
      unless Code.ensure_loaded?(Breeze.Server),
        do:
          raise(
            ArgumentError,
            "Add {:breeze, \"~> 0.5.5\"} to your Mix dependencies to explore bundles"
          )

      bundle = Bundle.load!(root)
      # Some OTP distributions omit os_mon. Use BackBreeze's default limit
      # explicitly so starting the explorer does not print a fallback diagnostic.
      # Leave any user-supplied setting (including :auto) alone.
      case {Application.ensure_all_started(:os_mon),
            Application.fetch_env(:back_breeze, :render_cache_max_memory_bytes)} do
        {{:error, _}, :error} ->
          Application.put_env(:back_breeze, :render_cache_max_memory_bytes, 256 * 1_024 * 1_024)

        _ ->
          :ok
      end

      {:ok, _} = Application.ensure_all_started(:breeze)
      Breeze.Server.run(view: __MODULE__, start_opts: [bundle: bundle], mouse: true)
    end

    @impl true
    def mount(opts, term) do
      bundle = Keyword.get(opts, :bundle) || Bundle.load!(Keyword.fetch!(opts, :root))
      names = Bundle.search(bundle, "")

      term =
        assign(term,
          bundle: bundle,
          relations: names,
          query: "",
          name: nil,
          mode: :rows,
          filter: "",
          filter_input: "",
          page: 0,
          table: nil,
          description: nil,
          row: 0,
          reference: 0,
          field: 0,
          fields: [],
          run_index: 0,
          overlay: nil,
          overlay_back: nil,
          error: nil,
          compact_detail?: false
        )

      {:ok, term |> select_relation(first_name(names)) |> focus("relations")}
    end

    @impl true
    def render(assigns) do
      height = max(assigns.breeze.terminal.height - 4, 8)
      wide? = assigns.breeze.terminal.width >= 100
      sidebar? = wide? or not assigns.compact_detail?

      assigns =
        assign(assigns,
          content_height: height,
          wide?: wide?,
          sidebar?: sidebar?,
          rows_height: max(height - 8, 3),
          layout_class: "grid grid-cols-#{if wide?, do: 2, else: 1} h-#{height}",
          sidebar_class:
            "border-r border-muted px-1 h-#{height} #{if wide?, do: "w-32", else: "w-full"}",
          content_class:
            "px-1 h-#{height} w-#{if wide?, do: assigns.breeze.terminal.width - 32, else: assigns.breeze.terminal.width}"
        )

      ~H"""
      <box class="w-screen h-screen bg text">
        <box class="w-full h-1 px-1 bg-panel font-bold overflow-hidden">
          Argus • {@bundle.manifest["analysis"] || "custom"} • {Bundle.text(Path.basename(@bundle.root))}
        </box>
        <box class="w-full h-1 px-1 text-muted overflow-hidden">
          {Bundle.text(@bundle.snapshot["directory"] || "No successful run")} • {if @bundle.run do
            "retained run"
          else
            "latest"
          end}
        </box>
        <box class={@layout_class}>
          <box :if={@sidebar?} class={@sidebar_class}>
            <box class="h-1 font-bold">Relations ({length(@relations)})</box>
            <.input
              id="search"
              class="w-full"
              input-value={@query}
              input-placeholder="/ search relation names"
              br-change="search"
              cursor-blink={false}
            >
              {if @query == "" do
                "/ search relation names"
              else
                Bundle.text(@query)
              end}
            </.input>
            <box class="h-1 text-muted">output / fact / intermediate</box>
            <.list
              id="relations"
              loop={false}
              list-selected={@name}
              br-change="relation"
              class={"overflow-hidden h-#{@content_height - 3}"}
            >
              <:item :for={relation <- @relations} value={relation.name}>
                {Bundle.text(relation.name)} {kind_marker(relation.kind)}
              </:item>
            </.list>
          </box>
          <box :if={@wide? or @compact_detail?} class={@content_class}>
            <box class="h-1 font-bold">
              {Bundle.text(@name || "No relation selected")} • {mode_title(@mode)}
            </box>
            <box class="h-1 text-muted">w rows  d description  r rules  b bundle  t runs</box>
            <box :if={@mode == :rows}>
              <box class="h-2 overflow-hidden">
                {Bundle.text(
                  if @description do
                    @description.doc || ""
                  else
                    ""
                  end
                )}
              </box>
              <.input
                id="filter"
                class="w-full"
                input-value={@filter_input}
                input-placeholder="f filter: column=value; Enter applies"
                br-change="filter_input"
                cursor-blink={false}
              >
                {if @filter_input == "" do
                  "f filter: column=value"
                else
                  Bundle.text(@filter_input)
                end}
              </.input>
              <box :if={@table} class="h-1 text-muted">
                Page {@page + 1} • {length(@table.rows)} rows • {if @table.more? do
                  "n next"
                else
                  "end"
                end} • N previous • {Bundle.text(@filter)}
              </box>
              <box :if={@table} class="h-1 overflow-hidden text-accent">
                {Enum.join(@table.fields, " | ")}
              </box>
              <.list
                :if={@table}
                id="rows"
                loop={false}
                list-selected={to_string(@row)}
                br-change="row"
                class={"overflow-hidden h-#{@rows_height}"}
              >
                <:item :for={{row, index} <- Enum.with_index(@table.rows)} value={to_string(index)}>
                  {row_summary(row)}
                </:item>
              </.list>
              <box :if={@table && @table.rows == []}>No matching rows.</box>
              <.scroll :if={@table == nil} id="unavailable" class={"h-#{@rows_height}"}>
                {Bundle.wrap(Bundle.unavailable(@bundle, @name, @error), @breeze.terminal.width - 6)}
              </.scroll>
            </box>
            <.scroll :if={@mode == :details} id="details" class={"h-#{@content_height - 2}"}>
              {if @description do
                Bundle.details(@description)
              else
                "No captured column definitions."
              end}
            </.scroll>
            <.list
              :if={@mode == :rules}
              id="rules"
              loop={false}
              list-selected={to_string(@reference)}
              br-change="reference"
              class={"overflow-hidden h-#{@content_height - 2}"}
            >
              <:item
                :for={{source, index} <- Enum.with_index(
        if @description do
          @description.sources
        else
          []
        end
      )}
                value={to_string(index)}
              >
                {Bundle.text("#{source.path}:#{source.line}  #{source.text}")}
              </:item>
            </.list>
            <.scroll :if={@mode == :bundle} id="bundle" class={"h-#{@content_height - 2}"}>
              {Bundle.overview(@bundle)}
            </.scroll>
            <.list
              :if={@mode == :runs}
              id="runs"
              loop={false}
              list-selected={to_string(@run_index)}
              br-change="run"
              class={"overflow-hidden h-#{@content_height - 2}"}
            >
              <:item :for={{run, index} <- Enum.with_index(@bundle.runs)} value={to_string(index)}>
                {run.directory}{if run.latest? do
                  " [latest]"
                else
                  ""
                end}{if run.indexed? do
                  ""
                else
                  " [no metadata]"
                end}
              </:item>
            </.list>
          </box>
        </box>
        <box class="w-full h-1 px-1 text-error overflow-hidden">{Bundle.text(@error || "")}</box>
        <box class="w-full h-1 px-1 bg-panel overflow-hidden">
          / search • Enter open • Tab focus • ? help • R refresh • q quit
        </box>
        <box
          :if={@overlay}
          focus-scope="trap"
          class={"absolute inset-1 z-10 border border-primary bg px-1 h-#{max(@breeze.terminal.height - 2, 6)} w-#{max(@breeze.terminal.width - 2, 20)}"}
        >
          <box class="h-1 font-bold overflow-hidden">{@overlay.title}</box>
          <.scroll
            :if={@overlay.kind == :text}
            id="source"
            class={"h-#{max(@breeze.terminal.height - 8, 3)}"}
          >
            {Bundle.wrap(@overlay.content, @breeze.terminal.width - 6)}
          </.scroll>
          <.list
            :if={@overlay.kind == :fields}
            id="fields"
            loop={false}
            list-selected={to_string(@field)}
            br-change="field"
            class={"overflow-hidden h-#{max(@breeze.terminal.height - 8, 3)}"}
          >
            <:item :for={{field, index} <- Enum.with_index(@fields)} value={to_string(index)}>
              {Bundle.text("#{field.name} = #{field.value}")}
            </:item>
          </.list>
          <box class="h-1 text-error overflow-hidden">{Bundle.text(@error || "")}</box>
          <box class="h-2 text-muted">{@overlay.note}</box>
        </box>
      </box>
      """
    end

    @impl true
    def handle_event("search", %{value: query}, term) do
      relations = Bundle.search(term.assigns.bundle, query)

      name =
        if Enum.any?(relations, &(&1.name == term.assigns.name)),
          do: term.assigns.name,
          else: first_name(relations)

      {:noreply, term |> assign(query: query, relations: relations) |> select_relation(name)}
    end

    def handle_event("search_done", _, term), do: {:noreply, focus(term, "relations")}

    def handle_event("relation", %{value: name}, term),
      do: {:noreply, select_relation(term, name)}

    def handle_event("filter_input", %{value: value}, term),
      do: {:noreply, assign(term, filter_input: value)}

    def handle_event("filter", %{value: value}, term) do
      {:noreply, term |> load_rows(value, 0) |> focus("rows")}
    end

    def handle_event("row", %{index: index}, term), do: {:noreply, assign(term, row: index)}

    def handle_event("reference", %{index: index}, term),
      do: {:noreply, assign(term, reference: index)}

    def handle_event("field", %{index: index}, term), do: {:noreply, assign(term, field: index)}
    def handle_event("run", %{index: index}, term), do: {:noreply, assign(term, run_index: index)}

    def handle_event(:input, %{"key" => "Escape"}, term), do: {:noreply, close(term)}
    def handle_event(:input, %{"key" => "q"}, term), do: {:stop, term}

    def handle_event(:input, %{"key" => "?"}, term),
      do: {:noreply, show_text(term, "Help", @help)}

    def handle_event(:input, %{"key" => "Enter"}, %{focused: "search"} = term),
      do: {:noreply, focus(term, "relations")}

    def handle_event(:input, %{"key" => "Enter"}, %{focused: "filter"} = term),
      do: {:noreply, term |> load_rows(term.assigns.filter_input, 0) |> focus("rows")}

    def handle_event(:input, %{"key" => "Enter"}, term), do: {:noreply, open(term)}
    def handle_event(:input, %{"key" => "/"}, term), do: {:noreply, focus(term, "search")}

    def handle_event(:input, %{"key" => "f"}, term),
      do: {:noreply, term |> mode(:rows) |> focus("filter")}

    def handle_event(:input, %{"key" => "x"}, term),
      do: {:noreply, term |> assign(filter_input: "") |> load_rows("", 0)}

    def handle_event(:input, %{"key" => "n"}, term) do
      if term.assigns.table && term.assigns.table.more?,
        do: {:noreply, load_rows(term, term.assigns.filter, term.assigns.page + 1)},
        else: {:noreply, term}
    end

    def handle_event(:input, %{"key" => "N"}, term),
      do: {:noreply, load_rows(term, term.assigns.filter, max(term.assigns.page - 1, 0))}

    def handle_event(:input, %{"key" => "d"}, term), do: {:noreply, mode(term, :details)}
    def handle_event(:input, %{"key" => "r"}, term), do: {:noreply, mode(term, :rules)}
    def handle_event(:input, %{"key" => "w"}, term), do: {:noreply, mode(term, :rows)}
    def handle_event(:input, %{"key" => "b"}, term), do: {:noreply, mode(term, :bundle)}
    def handle_event(:input, %{"key" => "t"}, term), do: {:noreply, mode(term, :runs)}
    def handle_event(:input, %{"key" => "R"}, term), do: {:noreply, reload(term, nil)}
    def handle_event(_, _, term), do: {:noreply, term}

    defp select_relation(term, nil), do: assign(term, name: nil, table: nil, description: nil)

    defp select_relation(term, name) do
      if term.assigns.name == name do
        term
      else
        term =
          term
          |> assign(
            name: name,
            page: 0,
            row: 0,
            reference: 0,
            filter: "",
            filter_input: "",
            table: nil,
            description: nil,
            error: nil
          )

        protect(term, fn ->
          description =
            Debug.describe!(term.assigns.bundle.root, name, run: term.assigns.bundle.run)

          term |> assign(description: description) |> load_rows("", 0)
        end)
      end
    end

    defp load_rows(%{assigns: %{name: nil}} = term, _, _), do: term

    defp load_rows(term, filter, page) do
      protect(term, fn ->
        result =
          Bundle.relation!(term.assigns.bundle, term.assigns.name, filter, page, @page_size)

        term
        |> reset("rows")
        |> assign(
          table: result.table,
          description: result.description,
          filter: filter,
          page: page,
          row: 0,
          error: nil
        )
      end)
    end

    defp mode(term, mode) do
      target =
        case mode do
          :rows -> "rows"
          :details -> "details"
          :rules -> "rules"
          :bundle -> "bundle"
          :runs -> "runs"
        end

      term
      |> assign(mode: mode, compact_detail?: true, overlay: nil, overlay_back: nil)
      |> focus(target)
    end

    defp open(%{assigns: %{overlay: %{kind: :fields}}} = term) do
      protect(term, fn ->
        field = Enum.at(term.assigns.fields, term.assigns.field)

        if Bundle.id?(field.value) do
          show_source(term, Bundle.location!(term.assigns.bundle, field.value))
        else
          show_text(
            term,
            field.name,
            Bundle.text(field.value),
            "Full field value. Escape returns to fields."
          )
        end
      end)
    end

    defp open(%{assigns: %{overlay: overlay}} = term) when not is_nil(overlay), do: term
    defp open(%{focused: "relations"} = term), do: mode(term, :rows)

    defp open(%{focused: "rows", assigns: %{table: table}} = term) when not is_nil(table) do
      case Enum.at(table.rows, term.assigns.row) do
        nil ->
          term

        [] ->
          show_text(
            term,
            "True (zero-column relation)",
            "This relation contains the empty tuple, representing true. It has no named fields."
          )

        row ->
          fields =
            for {name, value} <- Enum.zip(table.fields, row), do: %{name: name, value: value}

          overlay = %{
            kind: :fields,
            title: "Row #{term.assigns.page * @page_size + term.assigns.row + 1}",
            note: "Enter opens source for an ID, or the full value. Escape returns to rows."
          }

          term
          |> reset("fields")
          |> assign(fields: fields, field: 0, overlay: overlay)
          |> focus("fields")
      end
    end

    defp open(%{focused: "rules"} = term) do
      protect(term, fn ->
        sources = if term.assigns.description, do: term.assigns.description.sources, else: []
        source = Enum.at(sources, term.assigns.reference)

        if source do
          show_source(
            term,
            Bundle.source!(Path.join(term.assigns.bundle.root, source.path), source.line)
          )
        else
          assign(term, error: "No matching rule references")
        end
      end)
    end

    defp open(%{focused: "runs"} = term) do
      run = Enum.at(term.assigns.bundle.runs, term.assigns.run_index)
      if run, do: reload(term, run.directory), else: term
    end

    defp open(term), do: term

    defp reload(term, run) do
      protect(term, fn ->
        bundle = Bundle.load!(term.assigns.bundle.root, run)
        relations = Bundle.search(bundle, term.assigns.query)

        name =
          if Enum.any?(relations, &(&1.name == term.assigns.name)),
            do: term.assigns.name,
            else: first_name(relations)

        term
        |> assign(bundle: bundle, relations: relations, name: nil, overlay: nil, error: nil)
        |> select_relation(name)
        |> mode(:rows)
      end)
    end

    defp show_source(term, source), do: show_text(term, source.title, source.content, source.note)

    defp show_text(term, title, content, note \\ "Escape returns to exploration.") do
      back =
        if term.assigns.overlay && term.assigns.overlay.kind == :fields, do: term.assigns.overlay

      term
      |> reset("source")
      |> assign(
        overlay: %{kind: :text, title: title, content: content, note: note},
        overlay_back: back,
        error: nil
      )
      |> focus("source")
    end

    defp close(term) do
      cond do
        term.assigns.overlay_back ->
          term
          |> assign(overlay: term.assigns.overlay_back, overlay_back: nil, error: nil)
          |> focus("fields")

        term.assigns.overlay ->
          term |> assign(overlay: nil) |> mode(term.assigns.mode)

        term.focused in ["search", "filter"] ->
          focus(term, "relations")

        true ->
          term |> assign(compact_detail?: false) |> focus("relations")
      end
    end

    defp protect(term, fun) do
      fun.()
    rescue
      error in [ArgumentError, File.Error, Argus.MissingRelationError] ->
        assign(term, error: Exception.message(error))
    end

    defp first_name([]), do: nil
    defp first_name([relation | _]), do: relation.name
    defp kind_marker("output"), do: "[o]"
    defp kind_marker("fact"), do: "[f]"
    defp kind_marker("intermediate"), do: "[i]"

    defp mode_title(mode),
      do:
        %{rows: "Rows", details: "Description", rules: "Rules", bundle: "Bundle", runs: "Runs"}[
          mode
        ]

    defp row_summary(row),
      do: row |> Enum.map_join(" | ", &Bundle.text/1) |> String.replace("\n", "↵")
  end
else
  defmodule Argus.Debug.Explorer do
    @moduledoc false

    @spec run!(Path.t()) :: no_return()
    def run!(_root) do
      raise ArgumentError,
            "Add {:breeze, \"~> 0.5.5\"} to your Mix dependencies, then run " <>
              "mix deps.compile argus_beam --force to enable the bundle explorer"
    end
  end
end
