defmodule Argus.Test.Fixtures.PathTraversal do
  @moduledoc false
  @compile {:no_warn_undefined, [Phoenix.LiveView]}

  def unsafe(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      File.cp!(path, Path.join([base, entry.client_name]))
    end)
  end

  def safe(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      File.cp!(path, Path.join([base, Path.basename(entry.client_name)]))
    end)
  end

  def wrong_value(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      Path.basename(path)
      File.cp!(path, Path.join(base, entry.client_name))
    end)
  end

  def partial(socket, base, safe?) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      filename = if safe?, do: Path.basename(entry.client_name), else: entry.client_name
      File.cp!(path, Path.join(base, filename))
    end)
  end

  def opaque_branch(socket, base, safe?) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      filename =
        if safe?,
          do: Path.basename(entry.client_name),
          else: :persistent_term.get(entry.client_name)

      File.cp!(path, Path.join(base, filename))
    end)
  end

  def late(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      filename = Path.join(base, entry.client_name)
      File.cp!(path, filename)
      Path.basename(filename)
    end)
  end

  def expanded(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn _, entry ->
      File.write!(Path.expand(entry.client_name, base), "content")
    end)
  end

  def basename_as_directory(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn _, entry ->
      path = Path.join([base, Path.basename(entry.client_name), "file"])
      File.write!(path, "content")
    end)
  end

  def directory_removal(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn _, entry ->
      File.rm_rf!(Path.join(base, Path.basename(entry.client_name)))
    end)
  end

  def mixed_positions(socket) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn _, entry ->
      File.cp!(Path.basename(entry.client_name), entry.client_name)
    end)
  end

  def wrong_field(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      File.cp!(path, Path.join(base, entry.upload_config))
    end)
  end

  def wrong_root(socket, base, other) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, _entry ->
      File.cp!(path, Path.join(base, other.client_name))
    end)
  end

  def fixed_name(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, _entry ->
      File.cp!(path, Path.join(base, "upload"))
    end)
  end

  def generated_name(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, _entry ->
      name = Integer.to_string(System.unique_integer([:positive]))
      File.cp!(path, Path.join(base, name))
    end)
  end

  def ordinary_config(config, source),
    do: File.cp!(source, Path.join(config.dir, config.client_name))

  def unsafe_helper(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      File.cp!(path, joined(base, entry))
    end)
  end

  def safe_helper(socket, base) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      File.cp!(path, joined_leaf(base, entry))
    end)
  end

  defp joined(base, entry), do: Path.join(base, entry.client_name)
  defp joined_leaf(base, entry), do: Path.join(base, just_name(entry.client_name))
  defp just_name(filename), do: Path.basename(filename)
end
