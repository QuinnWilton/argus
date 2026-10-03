defmodule Argus.Test.Fixtures.HtmlProtocolValue do
  @moduledoc false
  defstruct [:payload]
end

defimpl String.Chars, for: Argus.Test.Fixtures.HtmlProtocolValue do
  def to_string(value), do: {:safe, value.payload}
end

defmodule Argus.Test.Fixtures.HtmlInjection do
  @moduledoc false
  @compile {:no_warn_undefined, [Phoenix.HTML, Phoenix.Controller, Plug.Conn, Plug.HTML, EQRCode]}

  def raw(label), do: Phoenix.HTML.raw(label)
  def stored(%{label: label}), do: Phoenix.HTML.raw(label)

  def render(assigns) do
    fn -> Phoenix.HTML.raw(assigns.label) end
  end

  def captured_fields(a, b, c, d, e, %{label: label}) do
    fn ->
      {a, b, c, d, e, Phoenix.HTML.raw(label)}
    end
  end

  def highlighted(label, search) do
    regex = Regex.compile!("(" <> Regex.escape(search) <> ")", "i")
    Phoenix.HTML.raw(String.replace(label, regex, "<b>\\0</b>"))
  end

  def escaped(label), do: Phoenix.HTML.raw(Plug.HTML.html_escape(label))

  def safe_highlight(label, search) when is_binary(label) do
    safe = label |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    regex = Regex.compile!("(" <> Regex.escape(search) <> ")", "i")
    Phoenix.HTML.raw(String.replace(safe, regex, "<b>\\0</b>"))
  end

  def safe_inline(label), do: Phoenix.HTML.raw("<b>" <> Plug.HTML.html_escape(label) <> "</b>")
  def literal, do: Phoenix.HTML.raw("<script>console.log('static')</script>")

  def script(label),
    do: Phoenix.HTML.raw("<script>const value='" <> Plug.HTML.html_escape(label) <> "'</script>")

  def attribute(label),
    do: Phoenix.HTML.raw("<a href='" <> Plug.HTML.html_escape(label) <> "'>link</a>")

  def unsafe_replacement(label, replacement),
    do: Phoenix.HTML.raw(String.replace(Plug.HTML.html_escape(label), "x", replacement))

  def unrelated(label, other) do
    Plug.HTML.html_escape(other)
    Phoenix.HTML.raw(label)
  end

  def after_use(label) do
    raw = Phoenix.HTML.raw(label)
    Plug.HTML.html_escape(label)
    raw
  end

  def one_branch(label, check) do
    content = if check, do: Plug.HTML.html_escape(label), else: label
    Phoenix.HTML.raw(content)
  end

  def both_branches(label, other, check) do
    content = if check, do: Plug.HTML.html_escape(label), else: Plug.HTML.html_escape(other)
    Phoenix.HTML.raw(content)
  end

  def safe_tuple(label), do: Phoenix.HTML.raw(Phoenix.HTML.html_escape({:safe, label}))
  def unknown_type(label), do: Phoenix.HTML.raw(Phoenix.HTML.html_escape(label))
  def controller(conn, label), do: Phoenix.Controller.html(conn, label)

  def response(conn, label) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html; charset=utf-8")
    |> Plug.Conn.send_resp(200, label)
  end

  def text_response(conn, label) do
    conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, label)
  end

  def other_response(conn, other, label) do
    Plug.Conn.put_resp_content_type(other, "text/html")
    Plug.Conn.send_resp(conn, 200, label)
  end

  def local_escaped(label), do: Phoenix.HTML.raw(escaped_markup(label))
  defp escaped_markup(label), do: "<div>" <> Plug.HTML.html_escape(label) <> "</div>"

  def helper_response(conn, label), do: safe_sink(conn, escaped_markup(label))
  defp safe_sink(conn, body), do: Phoenix.Controller.html(conn, body)

  def mixed_response(conn, label, flag) do
    body = if flag, do: escaped_markup(label), else: label
    mixed_sink(conn, body)
  end

  defp mixed_sink(conn, body), do: Phoenix.Controller.html(conn, body)

  def js_document(label) do
    Phoenix.HTML.raw("<script>const value='" <> js_escape(label) <> "';</script>")
  end

  def js_wrong_quote(label) do
    Phoenix.HTML.raw("<script>const value=\"" <> js_escape(label) <> "\";</script>")
  end

  def js_wrong_context(label) do
    Phoenix.HTML.raw("<div>" <> js_escape(label) <> "</div>")
  end

  def js_partial_branch(label, flag) do
    value = if flag, do: js_escape(label), else: label
    Phoenix.HTML.raw("<script>const value='" <> value <> "';</script>")
  end

  def js_missing_close_tag(label) do
    value =
      label
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")

    Phoenix.HTML.raw("<script>const value='" <> value <> "';</script>")
  end

  def js_wrong_order(label) do
    value =
      label
      |> String.replace("'", "\\'")
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("</", "<\\/")

    Phoenix.HTML.raw("<script>const value='" <> value <> "';</script>")
  end

  def js_truncated_escape(label) do
    value = js_escape(label)
    <<value::binary-size(3), _::binary>> = value
    Phoenix.HTML.raw("<script>const value='" <> value <> "';</script>")
  end

  def js_split_close_tag(a, b) do
    Phoenix.HTML.raw("<script>const value='" <> js_escape(a) <> js_escape(b) <> "';</script>")
  end

  def js_literal_slash(label) do
    Phoenix.HTML.raw("<script>const value='" <> js_escape(label) <> "/script>'; </script>")
  end

  def js_after_escape(label) do
    value = js_escape(label) |> String.replace("x", "'")
    Phoenix.HTML.raw("<script>const value='" <> value <> "';</script>")
  end

  defp js_escape(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("</", "<\\/")
  end

  def qr_svg(value), do: Phoenix.HTML.raw(EQRCode.svg(EQRCode.encode(value), width: 200))

  def qr_dynamic_options(value, options),
    do: Phoenix.HTML.raw(EQRCode.svg(EQRCode.encode(value), options))

  def qr_dynamic_matrix(matrix), do: Phoenix.HTML.raw(EQRCode.svg(matrix, width: 200))
  def qr_attribute(value, id), do: Phoenix.HTML.raw(EQRCode.svg(EQRCode.encode(value), id: id))

  def qr_literal_attribute(value),
    do: Phoenix.HTML.raw(EQRCode.svg(EQRCode.encode(value), color: "red;fill:url(x)"))

  def qr_local(value), do: Phoenix.HTML.raw(generated_svg(value))
  defp generated_svg(value), do: EQRCode.svg(EQRCode.encode(value), width: 200)

  def captures_sink(conn), do: fn value -> captured_sink(conn, value) end
  defp captured_sink(conn, value), do: Phoenix.Controller.html(conn, value)

  def js_response(conn, value) do
    body = "<script>const value='" <> js_escape(value) <> "';</script>"
    js_sink(conn, body)
  end

  defp js_sink(conn, body), do: Phoenix.Controller.html(conn, body)

  def replacement_changes_tag(value) do
    safe = "<span>" <> Plug.HTML.html_escape(value) <> "</span>"
    Phoenix.HTML.raw(String.replace(safe, "span", "script"))
  end

  def replacement_after_highlight(value) do
    safe = String.replace(Plug.HTML.html_escape(value), ~r/.+/, "<span>\\0</span>")
    Phoenix.HTML.raw(String.replace(safe, "span", "script"))
  end

  def protocol_highlight(label, search) do
    safe = label |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    regex = Regex.compile!("(" <> Regex.escape(search) <> ")", "i")
    Phoenix.HTML.raw(String.replace(safe, regex, "<b>\\0</b>"))
  end

  def builtin_binary_conversion(label) when is_binary(label) do
    Phoenix.HTML.raw(Phoenix.HTML.html_escape(String.Chars.to_string(label)))
  end

  def forged_protocol(value) do
    %Argus.Test.Fixtures.HtmlProtocolValue{payload: value}
    |> String.Chars.to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.raw()
  end
end
