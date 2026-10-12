defmodule AgentboardWeb.MessageExportController do
  @moduledoc """
  Dashboard download of read-only board message history as NDJSON: one API
  message object per line, in `created_at`/`id` order, streamed in bounded
  pages. Available in every message mode; reading never acknowledges.
  """
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  alias Agentboard.MessageHistory

  def download(conn, _params) do
    conn = fetch_query_params(conn)

    filters =
      conn.query_params
      |> Map.take(~w(to task))
      |> Map.reject(fn {_, value} -> value == "" end)

    case MessageHistory.export_page(filters) do
      {:ok, page} ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=agentboard-messages.ndjson"
        )
        |> put_resp_content_type("application/x-ndjson")
        |> send_chunked(200)
        |> stream(filters, page)

      error ->
        AgentboardWeb.APIController.reply(conn, error)
    end
  end

  defp stream(conn, filters, %{"messages" => records, "next_cursor" => next}) do
    case chunk(conn, Enum.map(records, &[MessageHistory.encode(&1), ?\n])) do
      {:ok, conn} -> next_page(conn, filters, next)
      # The client went away; nothing further to deliver.
      {:error, _} -> conn
    end
  end

  defp next_page(conn, _filters, nil), do: conn

  defp next_page(conn, filters, cursor) do
    case MessageHistory.export_page(Map.put(filters, "cursor", cursor)) do
      {:ok, page} ->
        stream(conn, filters, page)

      # Headers are sent; abort the transfer instead of completing a
      # truncated file that would look like a whole export.
      {:error, _code, message} ->
        raise "board message export interrupted: #{message}"
    end
  end
end
