defmodule Agentboard.Auth do
  @moduledoc "Captain credential custody and verified API principal resolution."
  use Ash.Domain, backwards_compatible_interface?: false

  resources do
    resource(Agentboard.Auth.Credential)
    resource(Agentboard.Auth.Observation)
  end

  alias Agentboard.{Captain, Input, Repo}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Agent
  alias Agentboard.Auth.{APIAuthPolicy, Credential, Observation}
  require Ash.Query
  require Logger

  @actor %{"agent" => "auth-system", "model" => "system", "harness" => "ash"}

  def mode, do: Application.get_env(:agentboard, :agent_auth_mode, "off")

  def administer(id, action, data, capability) do
    cond do
      not Captain.authorized?(capability) ->
        {:error, "forbidden", "Captain capability required"}

      not Input.slug?(id) ->
        {:error, "invalid_input", "Valid agent ID required"}

      action not in ~w(issue rotate revoke list) ->
        {:error, "invalid_input", "Unknown credential action"}

      not is_map(data) or Enum.any?(Map.keys(data), &(&1 not in ~w(scope credential_id))) ->
        {:error, "invalid_input", "Invalid credential fields"}

      true ->
        Ops.transaction(fn -> administer_locked(id, action, data) end)
    end
  end

  defp administer_locked(id, action, data) do
    # Serializes issue, rotate, revoke and verification for this identity.
    case Repo.statement!("SELECT id FROM agents WHERE id=$1 FOR UPDATE", [id]).rows do
      [] -> Ops.reject("not_found", "Agent must be registered")
      _ -> :ok
    end

    rows = Credential |> Ash.Query.filter(agent_id == ^id) |> Ash.read!()
    stamp = Ops.now()
    agent = Ash.get!(Agent, id)

    case action do
      "list" ->
        %{credentials: Enum.map(rows, &metadata/1)}

      "revoke" ->
        target = data["credential_id"]

        if not is_nil(target) and not Enum.any?(rows, &(&1.id == target)),
          do: Ops.reject("not_found", "Credential not found for this agent")

        Enum.each(rows, fn row ->
          if is_nil(row.revoked_at) and (is_nil(target) or row.id == target),
            do: Ops.update(row, :revoke, %{revoked_at: stamp}, @actor)
        end)

        %{credentials: id |> credentials() |> Enum.map(&metadata/1)}

      mint ->
        scope =
          data["scope"] ||
            if(id == Application.get_env(:agentboard, :coordinator_id),
              do: "coordinator",
              else: "agent"
            )

        if APIAuthPolicy.reserved?(id, agent.harness, agent.kind) or
             not is_nil(agent.retired_at) or scope not in ~w(agent coordinator),
           do:
             Ops.reject(
               "forbidden",
               "Credentials require an active, non-reserved agent and supported scope"
             )

        if scope == "coordinator" != (id == Application.get_env(:agentboard, :coordinator_id)),
          do:
            Ops.reject(
              "forbidden",
              "Coordinator scope belongs only to the configured coordinator"
            )

        if mint == "rotate",
          do:
            Enum.each(rows, fn row ->
              if is_nil(row.revoked_at),
                do: Ops.update(row, :revoke, %{revoked_at: stamp}, @actor)
            end)

        token = "abt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        hash = digest(token)

        credential =
          Ops.create(
            Credential,
            :issue,
            %{
              id: Ecto.UUID.generate(),
              agent_id: id,
              token_hash: hash,
              fingerprint: String.slice(hash, 0, 12),
              scope: scope,
              issuer: "captain",
              created_at: stamp
            },
            @actor
          )

        %{credential: metadata(credential), token: token}
    end
  end

  defp credentials(id), do: Credential |> Ash.Query.filter(agent_id == ^id) |> Ash.read!()

  def metadata(row) do
    row
    |> Map.take(~w(id agent_id fingerprint scope issuer created_at last_used_at revoked_at)a)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      pair -> pair
    end)
  end

  def verify(nil), do: {:ok, nil}

  def verify("abt_" <> suffix = token) when byte_size(suffix) == 43 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, suffix),
      do: verify_token(token),
      else: {:ok, nil}
  end

  def verify(_), do: {:ok, nil}

  defp verify_token(token) do
    hash = digest(token)

    Ops.transaction(fn ->
      # Rotation and verification serialize on the agent row. Authentication is
      # a request-admission decision: revocation does not cancel an operation
      # already admitted. Long-lived watches revalidate before each snapshot.
      case Credential |> Ash.Query.filter(token_hash == ^hash) |> Ash.read_one!() do
        nil ->
          nil

        candidate ->
          Repo.statement!("SELECT id FROM agents WHERE id=$1 FOR UPDATE", [candidate.agent_id])
          row = Ash.get!(Credential, candidate.id, not_found_error?: false)
          agent = Ash.get!(Agent, candidate.agent_id, not_found_error?: false)

          if row &&
               APIAuthPolicy.credential_allowed?(
                 row,
                 agent,
                 Application.get_env(:agentboard, :coordinator_id)
               ) do
            Ops.update(row, :use, %{last_used_at: Ops.now()}, @actor)

            %{
              agent_id: row.agent_id,
              scope: row.scope,
              credential_id: row.id,
              model: agent.model,
              harness: agent.harness
            }
          end
      end
    end)
  end

  def observe(attributed, token, method, route) do
    with {:ok, principal} <- verify(token) do
      outcome =
        cond do
          is_nil(token) -> "anonymous"
          is_nil(principal) -> "invalid"
          principal.agent_id != attributed -> "actor_mismatch"
          true -> "matched"
        end

      with {:ok, _} <- record(outcome, attributed, principal, method, route) do
        :telemetry.execute([:agentboard, :auth, :write], %{count: 1}, %{
          mode: "observe",
          outcome: outcome
        })

        if outcome != "matched", do: Logger.info("agentboard auth observe outcome=#{outcome}")
        {:ok, principal}
      end
    end
  end

  defp record(outcome, attributed, principal, method, route) do
    Ops.transaction(fn ->
      # Caller headers are untrusted: only registered IDs enter durable evidence.
      attributed =
        if Input.slug?(attributed) and Ash.get!(Agent, attributed, not_found_error?: false),
          do: attributed

      Ops.create(
        Observation,
        :record,
        %{
          id: Ecto.UUID.generate(),
          outcome: outcome,
          attributed_agent_id: attributed,
          verified_agent_id: principal && principal.agent_id,
          method: method,
          route: route,
          created_at: Ops.now()
        },
        @actor
      )

      :ok
    end)
  end

  def report do
    with {:ok, %{rows: counts}} <-
           Repo.statement(
             "SELECT outcome,count(*) FROM agent_auth_observations WHERE created_at > clock_timestamp()-interval '24 hours' GROUP BY outcome",
             []
           ),
         {:ok, %{rows: rows}} <-
           Repo.statement(
             "SELECT to_jsonb(o) FROM agent_auth_observations o ORDER BY created_at DESC,id DESC LIMIT 50",
             []
           ) do
      {:ok,
       %{
         "mode" => mode(),
         "window" => "24 hours",
         "counts" => Map.new(counts, fn [key, n] -> {key, n} end),
         "recent" => Enum.map(rows, &hd/1)
       }}
    else
      _ -> {:error, "unavailable", "Authentication report unavailable"}
    end
  end

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
