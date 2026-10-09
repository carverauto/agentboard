defmodule AgentboardWeb.Plugs.AgentAuth do
  @moduledoc "Fail-closed agent authentication, with independent captain, worker and webhook boundaries."
  import Plug.Conn
  alias Agentboard.{Auth, Captain, Input}
  alias Agentboard.Auth.APIAuthPolicy, as: Policy
  require Logger

  def init(opts), do: opts

  def call(conn, _) do
    info = route_info(conn)

    case Auth.mode() do
      "off" -> conn
      "observe" -> observe(conn, info)
      "enforce" -> enforce(conn, info)
      _ -> reject(conn, "unavailable", "Authentication configuration is unavailable")
    end
  end

  # This helper is the only controller source of effective attribution. In
  # enforce mode an absent assignment never falls back to caller headers.
  def actor(conn) do
    if Auth.mode() == "enforce",
      do: Map.get(conn.assigns, :trusted_actor, %{}),
      else: legacy_actor(conn)
  end

  def bearer(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:ok, nil}

      ["Bearer " <> value] ->
        if Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, value),
          do: {:ok, value},
          else: {:error, "unauthorized", "Malformed authorization"}

      _ ->
        {:error, "unauthorized", "Malformed authorization"}
    end
  end

  # Existing streams are admitted again before every data snapshot. Revocation,
  # retirement, scope/config changes and verification outages end the stream.
  def stream_authorized?(conn) do
    if Auth.mode() == "enforce" do
      with {:ok, token} when is_binary(token) <- bearer(conn),
           {:ok, principal} when is_map(principal) <- Auth.verify(token),
           :ok <- attribution(conn, principal),
           true <- principal == conn.assigns[:authenticated_agent],
           true <- Policy.allowed?(principal, route_info(conn), conn.method, conn.query_params) do
        true
      else
        _ -> false
      end
    else
      Auth.mode() in ["off", "observe"]
    end
  end

  defp enforce(conn, info) do
    boundary = Policy.boundary(info)

    conn =
      if boundary == :public, do: conn, else: put_resp_header(conn, "cache-control", "no-store")

    case boundary do
      boundary when boundary in [:public, :independent] -> conn
      :captain -> enforce_captain(conn, info)
      :agent -> enforce_agent(fetch_query_params(conn), info)
      :deny -> reject(conn, "forbidden", "API operation has no authentication policy")
    end
  end

  defp enforce_captain(conn, info) do
    with {:ok, _} <- bearer(conn),
         :ok <- single_headers(conn),
         true <- captain_authorized?(conn, info) do
      conn
    else
      false -> reject(conn, "forbidden", "Captain capability required")
      {:error, code, message} -> reject(conn, code, message)
    end
  end

  defp enforce_agent(conn, info) do
    with {:ok, token} <- bearer(conn), :ok <- single_headers(conn) do
      cond do
        Policy.bootstrap?(info) and bootstrap_authorized?(conn) -> bootstrap(conn)
        Captain.authorized?(Captain.authenticate_header(conn)) -> captain(conn, info)
        true -> agent(conn, info, token)
      end
    else
      {:error, code, message} -> reject(conn, code, message)
    end
  end

  defp agent(conn, info, token) do
    case Auth.verify(token) do
      {:ok, principal} when is_map(principal) ->
        conn =
          conn
          |> assign(:authenticated_agent, principal)
          |> AgentboardWeb.Plugs.RateLimit.authenticated_agent()

        if conn.halted do
          conn
        else
          with :ok <- attribution(conn, principal),
               true <- Policy.allowed?(principal, info, conn.method, conn.query_params) do
            assign(conn, :trusted_actor, principal_actor(principal))
          else
            false -> reject(conn, "forbidden", "Credential scope does not permit this operation")
            {:error, code, message} -> reject(conn, code, message)
          end
        end

      {:ok, nil} ->
        reject(conn, "unauthorized", "A valid agent credential is required")

      {:error, code, message} ->
        reject(conn, code, message)
    end
  end

  defp captain(conn, info) do
    if Policy.captain_operation?(info, conn.path_params) do
      actor = %{"agent" => "captain", "model" => "human", "harness" => "captain"}

      # Existing board operations require a registered audit identity. Like the
      # captain UI, administrative writes ensure this one fixed identity.
      result =
        if conn.method in ["GET", "HEAD"],
          do: {:ok, nil},
          else: Agentboard.Board.register(actor, %{"name" => "Captain"})

      case result do
        {:ok, _} -> conn |> assign(:api_auth_kind, :captain) |> assign(:trusted_actor, actor)
        {:error, code, message} -> reject(conn, code, message)
      end
    else
      reject(conn, "forbidden", "Captain capability does not authorize this agent operation")
    end
  end

  defp bootstrap(conn) do
    actor = legacy_actor(conn)

    with {:ok, _} <- Input.actor(actor),
         false <- Policy.reserved?(actor["agent"], actor["harness"], conn.body_params["kind"]) do
      conn |> assign(:api_auth_kind, :captain_bootstrap) |> assign(:trusted_actor, actor)
    else
      true -> reject(conn, "forbidden", "Reserved identities cannot be bootstrapped as agents")
      {:error, code, message} -> reject(conn, code, message)
    end
  end

  defp principal_actor(principal),
    do: %{
      "agent" => principal.agent_id,
      "model" => principal.model,
      "harness" => principal.harness
    }

  defp attribution(conn, principal) do
    valid =
      Enum.all?(principal_actor(principal), fn {key, expected} ->
        get_req_header(conn, "x-agentboard-" <> key) in [[], [expected]]
      end)

    if valid,
      do: :ok,
      else: {:error, "forbidden", "Attribution does not match the authenticated identity"}
  end

  defp single_headers(conn) do
    if Enum.all?(~w(agent model harness captain-token), fn name ->
         case get_req_header(conn, "x-agentboard-" <> name) do
           [] -> true
           [value] -> is_binary(value) and String.trim(value) != ""
           _ -> false
         end
       end),
       do: :ok,
       else: {:error, "unauthorized", "Malformed attribution or capability headers"}
  end

  defp bootstrap_authorized?(conn),
    do:
      Captain.authorized?(Captain.authenticate_header(conn)) or
        Captain.authorized?(Captain.authenticate_header(conn, "x-agentboard-captain-token"))

  defp captain_authorized?(conn, %{plug: AgentboardWeb.AgentTokenController}),
    do: bootstrap_authorized?(conn)

  defp captain_authorized?(conn, _), do: Captain.authorized?(Captain.authenticate_header(conn))

  defp observe(conn, info) do
    if conn.method not in ~w(GET HEAD OPTIONS) and ordinary?(info) do
      token =
        case bearer(conn) do
          {:ok, value} -> value
          _ -> :invalid
        end

      actor = legacy_actor(conn)["agent"]

      case Auth.observe(actor, token, conn.method, info.route) do
        {:ok, principal} ->
          assign(conn, :authenticated_agent, principal)

        {:error, _, _} ->
          :telemetry.execute([:agentboard, :auth, :write], %{count: 1}, %{
            mode: "observe",
            outcome: "observation_unavailable"
          })

          Logger.info("agentboard auth observe outcome=observation_unavailable")
          assign(conn, :authenticated_agent, nil)
      end
    else
      conn
    end
  end

  defp legacy_actor(conn) do
    Map.new(~w(agent model harness), fn key ->
      value =
        case get_req_header(conn, "x-agentboard-" <> key) do
          [value] -> value
          _ -> nil
        end

      {key, value}
    end)
  end

  defp route_info(conn),
    do: Phoenix.Router.route_info(AgentboardWeb.Router, conn.method, conn.path_info, conn.host)

  defp ordinary?(%{plug: controller}),
    do:
      controller not in [
        AgentboardWeb.WorkerController,
        AgentboardWeb.CaptainController,
        AgentboardWeb.FleetLoadoutController,
        AgentboardWeb.AgentTokenController
      ]

  defp ordinary?(_), do: false

  defp reject(conn, code, message) do
    status =
      case code do
        "unauthorized" -> 401
        "forbidden" -> 403
        c when c in ["invalid_input", "invalid_context"] -> 422
        _ -> 503
      end

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message}}))
    |> halt()
  end
end
