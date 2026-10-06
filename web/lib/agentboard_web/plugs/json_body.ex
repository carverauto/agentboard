defmodule AgentboardWeb.Plugs.JSONBody do
  import Plug.Conn

  def init(_),
    do:
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["application/json"],
        json_decoder: Jason,
        length: 5_242_880
      )

  def call(conn, options) do
    Plug.Parsers.call(conn, options)
  rescue
    _error in [
      Plug.Parsers.ParseError,
      Plug.Parsers.UnsupportedMediaTypeError,
      Plug.Parsers.RequestTooLargeError
    ] ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        400,
        Jason.encode!(%{
          error: %{
            code: "invalid_input",
            message: "Request must be valid JSON no larger than 5 MiB"
          }
        })
      )
      |> halt()
  end
end

