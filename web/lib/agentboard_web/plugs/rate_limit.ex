defmodule AgentboardWeb.Plugs.RateLimit do
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    agent =
      if Agentboard.Auth.mode() in ["off", "observe"] do
        case get_req_header(conn, "x-agentboard-agent") do
          [value] when byte_size(value) <= 128 -> value
          _ -> nil
        end
      end

    # Forwarded headers are untrusted; Gateway proxy support must be explicitly configured.
    # Enforced requests cannot spend somebody else's agent budget before proof.
    limit(conn, Agentboard.RateLimits.check(conn.remote_ip, agent))
  end

  def authenticated_agent(%{assigns: %{authenticated_agent: %{agent_id: id}}} = conn)
      when is_binary(id),
      do: limit(conn, Agentboard.RateLimits.check_agent(id))

  defp limit(conn, result) do
    case result do
      :ok ->
        conn

      {:error, :rate_limited, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> reject(429, "rate_limited", "API request limit exceeded")

      {:error, :unavailable} ->
        reject(conn, 503, "unavailable", "API limiter unavailable")
    end
  end

  defp reject(conn, status, code, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message}}))
    |> halt()
  end
end
