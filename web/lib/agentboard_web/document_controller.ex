defmodule AgentboardWeb.DocumentController do
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Agentboard.Documents

  @sandbox "sandbox allow-scripts allow-downloads; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'"

  def show(conn, %{"id" => id}) do
    case Documents.fetch(id) do
      {:ok, d} ->
        title = d["title"] |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        conn
        |> safe_headers()
        |> put_resp_header(
          "content-security-policy",
          "default-src 'none'; style-src 'unsafe-inline'; frame-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'"
        )
        |> html("""
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>#{title}</title>
        <style>body{margin:0;height:100dvh;display:flex;flex-direction:column;font:15px system-ui;background:#edf2f8;color:#172f48}header{padding:16px;display:flex;gap:16px;align-items:center;flex-wrap:wrap}strong{flex:1;min-width:0;overflow-wrap:anywhere}a{color:#175bb8}iframe{display:block;width:100%;flex:1;min-height:0;border:0}@media(prefers-color-scheme:dark){body{background:#152536;color:#e4edf6}a{color:#8ebdff}}</style></head>
        <body><header><a href="/tasks/#{d["task_id"]}">Back to task</a><strong>#{title}</strong><a href="/documents/#{d["id"]}/download">Download HTML</a></header>
        <iframe title="#{title}" sandbox="allow-scripts allow-downloads" referrerpolicy="no-referrer" src="/documents/#{d["id"]}/html"></iframe></body></html>
        """)

      error ->
        error(conn, error)
    end
  end

  def content(conn, %{"id" => id}), do: serve(conn, id, false)
  def download(conn, %{"id" => id}), do: serve(conn, id, true)

  defp serve(conn, id, download) do
    case Documents.fetch(id) do
      {:ok, d} ->
        conn = conn |> safe_headers() |> put_resp_header("content-security-policy", @sandbox)

        conn =
          if download,
            do:
              put_resp_header(
                conn,
                "content-disposition",
                "attachment; filename=agentboard-document-#{d["id"]}.html"
              ),
            else: conn

        conn |> put_resp_content_type("text/html") |> send_resp(200, d["html"])

      error ->
        error(conn, error)
    end
  end

  defp safe_headers(conn),
    do:
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

  defp error(conn, {:error, code, _}),
    do:
      send_resp(
        conn,
        case code do
          "not_found" -> 404
          "invalid_input" -> 422
          _ -> 503
        end,
        "Documentation unavailable"
      )
end

