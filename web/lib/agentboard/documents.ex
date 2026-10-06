defmodule Agentboard.Documents do
  alias Agentboard.{Board, Input}

  def push(id, actor, data) do
    with {:ok, actor} <- Input.actor(actor), true <- Input.slug?(id), :ok <- validate(data) do
      digest =
        :crypto.hash(
          :sha256,
          Jason.encode!(data |> Enum.sort() |> Enum.map(fn {k, v} -> [k, v] end))
        )
        |> Base.encode16(case: :lower)

      Board.query_one("SELECT board_document($1,$2,$3,$4,$5,$6)", [
        id,
        data,
        digest,
        actor["agent"],
        actor["model"],
        actor["harness"]
      ])
      |> links()
    else
      false -> {:error, "invalid_input", "Invalid task ID"}
      error -> error
    end
  end

  def list(id) do
    if Input.slug?(id) do
      Board.query_one(
        """
        SELECT jsonb_build_object('documents',coalesce((SELECT jsonb_agg(board_document_meta(d) ORDER BY d.id DESC)
          FROM task_documents d WHERE d.task_id=t.id),'[]')) FROM tasks t WHERE t.id=$1
        """,
        [id]
      )
      |> links()
    else
      {:error, "invalid_input", "Invalid task ID"}
    end
  end

  def fetch(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 ->
        Board.query_one("SELECT to_jsonb(d) FROM task_documents d WHERE id=$1", [n])

      _ ->
        {:error, "invalid_input", "Document ID must be positive"}
    end
  end

  defp links({:ok, %{"document" => d} = data}), do: {:ok, Map.put(data, "document", link(d))}

  defp links({:ok, %{"documents" => ds} = data}),
    do: {:ok, Map.put(data, "documents", Enum.map(ds, &link/1))}

  defp links(error), do: error

  defp link(d),
    do:
      d
      |> Map.put("viewer_url", "/documents/#{d["id"]}")
      |> Map.put("download_url", "/documents/#{d["id"]}/download")

  defp validate(data) when is_map(data) do
    valid =
      Enum.all?(data, fn
        {"kind", v} ->
          v in ~w(archify openspec)

        {"title", v} ->
          text?(v, 256)

        {"html", v} ->
          is_binary(v) and String.valid?(v) and byte_size(v) in 1..2_097_152 and
            not String.contains?(v, <<0>>) and
            Regex.match?(~r/\A\s*(?:<!doctype\s+html[^>]*>\s*)?<html\b/i, v)

        {"pr_url", v} ->
          is_binary(v) and byte_size(v) <= 2048 and
            match?(:ok, Input.task("link", %{"pr_url" => v}))

        {"source_revision", v} ->
          is_binary(v) and Regex.match?(~r/\A[0-9a-f]{40}\z/, v)

        {"proposal_name", v} ->
          Input.slug?(v)

        _ ->
          false
      end)

    if valid and Enum.all?(~w(kind title html), &Map.has_key?(data, &1)),
      do: :ok,
      else:
        {:error, "invalid_input",
         "Document requires kind archify/openspec, title and standalone UTF-8 HTML up to 2 MiB"}
  end

  defp validate(_), do: {:error, "invalid_input", "Document payload must be an object"}
  defp text?(v, n), do: Input.text?(v) and byte_size(v) <= n and not String.contains?(v, <<0>>)
end

