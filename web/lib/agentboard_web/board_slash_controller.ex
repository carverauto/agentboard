defmodule AgentboardWeb.BoardSlashController do
  @moduledoc """
  Mattermost `/board` slash-command endpoint, separate from agent, captain and
  helper credentials. Mattermost authenticates with the slash command's own
  token, compared in constant time against the configured secret. Unavailable
  while work intake is off.
  """
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.Intake
  alias Agentboard.Intake.Slash

  def create(conn, _) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    token = token()

    cond do
      not Intake.enabled?() ->
        error(conn, 404, "intake_disabled", "Work intake is disabled on this server")

      not is_binary(token) or byte_size(token) < 16 ->
        error(conn, 503, "unconfigured", "The /board slash command is not configured")

      true ->
        verify(conn, token)
    end
  end

  # Mattermost posts the command as an urlencoded form.
  defp verify(conn, token) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 5000) do
      {:ok, body, conn} ->
        params = URI.decode_query(body)
        sent = params["token"]

        if is_binary(sent) and byte_size(sent) == byte_size(token) and
             Plug.Crypto.secure_compare(sent, token),
           do: json(conn, Slash.run(params)),
           else: error(conn, 401, "unauthorized", "Invalid slash command token")

      {:more, _, conn} ->
        error(conn, 413, "too_large", "Slash command body is too large")

      {:error, _} ->
        error(conn, 400, "invalid_body", "Slash command body could not be read")
    end
  end

  # A token file is re-read on every request so rotation needs no restart.
  defp token do
    case Application.get_env(:agentboard, :mattermost_slash_token_file) do
      path when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, value} -> String.trim(value)
          {:error, _} -> nil
        end

      _ ->
        Application.get_env(:agentboard, :mattermost_slash_token)
    end
  end

  defp error(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
end
