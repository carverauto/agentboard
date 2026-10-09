defmodule Agentboard.FleetLoadout do
  @moduledoc "Dormant desired configuration only. No enrollment, activation, claiming or host control."
  alias Agentboard.{Availability, Captain, Repo, SeatScope}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.Agent
  alias Agentboard.FleetLoadout.{Binding, Configuration, Receipt}
  @actor %{"agent" => "captain", "model" => "human", "harness" => "captain", :fleet_admin => true}
  @seat_fields ~w(seat_id agent_id harness desired_host_id desired_model desired_effort scope_revision)

  def show(id, capability) do
    with :ok <- authority(capability), :ok <- fleet_id(id) do
      Ops.transaction(fn ->
        Availability.lock_admission()

        %{
          "loadout" => project(Ash.get!(Configuration, id, not_found_error?: false), id),
          "replayed" => false
        }
      end)
    end
  end

  def replace(id, capability, data) do
    with :ok <- authority(capability), :ok <- fleet_id(id), {:ok, normalized} <- validate(data) do
      Ops.transaction(fn ->
        # This is the same lock/order as SeatScope and Availability: policy first,
        # then sorted agent row locks. Retire/register/heartbeat take agent locks.
        Availability.lock_policy()
        receipt_id = digest([id, normalized["idempotency_key"]])

        case Ash.get!(Receipt, receipt_id, not_found_error?: false) do
          nil ->
            replace_locked(id, normalized, receipt_id)

          receipt ->
            if receipt.request != normalized,
              do: Ops.reject("conflict", "Idempotency key was used for a different replacement")

            Map.put(receipt.response, "replayed", true)
        end
      end)
    end
  end

  defp replace_locked(id, data, receipt_id) do
    prior = Ash.get!(Configuration, id, not_found_error?: false)
    revision = if prior, do: prior.revision, else: 0

    if revision != data["revision"],
      do: Ops.reject("conflict", "Fleet loadout revision changed; reload")

    seats = data["seats"]
    agents = seats |> Enum.map(& &1["agent_id"]) |> Enum.sort()
    Enum.each(agents, &Repo.statement!("SELECT id FROM agents WHERE id=$1 FOR SHARE", [&1]))
    Enum.each(seats, &validate_reference!(&1, id))

    used =
      Configuration
      |> Ash.read!()
      |> Enum.reject(&(&1.id == id))
      |> Enum.flat_map(& &1.configuration["seats"])
      |> Enum.map(& &1["agent_id"])
      |> MapSet.new()

    if Enum.any?(agents, &MapSet.member?(used, &1)),
      do: Ops.reject("conflict", "Agent is already configured in another fleet")

    stamp = Ops.now()

    attrs = %{
      configuration: %{"seats" => seats},
      revision: revision + 1,
      changed_by: "captain",
      updated_at: stamp
    }

    row =
      if prior,
        do: Ops.update(prior, :replace, attrs, @actor, revision),
        else: Ops.create(Configuration, :record, Map.put(attrs, :id, id), @actor)

    Enum.each(seats, fn seat ->
      key = digest([id, seat["seat_id"]])

      unless Ash.get!(Binding, key, not_found_error?: false) do
        Ops.create(
          Binding,
          :record,
          %{
            id: key,
            fleet_id: id,
            seat_id: seat["seat_id"],
            agent_id: seat["agent_id"],
            harness: seat["harness"],
            created_at: stamp
          },
          @actor
        )
      end
    end)

    response = %{"loadout" => project(row, id), "replayed" => false}

    Ops.create(
      Receipt,
      :record,
      %{
        id: receipt_id,
        fleet_id: id,
        idempotency_key: data["idempotency_key"],
        request: data,
        response: response,
        created_at: stamp
      },
      @actor
    )

    response
  end

  defp validate_reference!(seat, id) do
    agent = Ops.fetch!(Agent, seat["agent_id"], "Agent must be registered", "invalid_input")

    if agent.retired_at != nil or agent.kind != "seat" or agent.harness != seat["harness"],
      do:
        Ops.reject(
          "invalid_input",
          "Fleet seat requires a nonretired seat identity with its registered harness"
        )

    scope = SeatScope.get(agent.id)

    unless scope && scope.revision == seat["scope_revision"],
      do:
        Ops.reject("conflict", "Managed seat scope revision changed or is missing; reload scope")

    case Ash.get!(Binding, digest([id, seat["seat_id"]]), not_found_error?: false) do
      nil ->
        :ok

      binding ->
        if binding.agent_id != agent.id or binding.harness != agent.harness,
          do:
            Ops.reject(
              "conflict",
              "Seat ID is permanently bound to its original agent and harness"
            )
    end
  end

  defp project(row, id) do
    seats = if row, do: row.configuration["seats"], else: []

    %{
      "id" => id,
      "revision" => if(row, do: row.revision, else: 0),
      "enabled" => false,
      "seat_count" => length(seats),
      "activation_state" => "not_activatable",
      "catalog_status" => "unverified",
      "host_status" => "unverified",
      "changed_by" => if(row, do: row.changed_by, else: nil),
      "updated_at" => if(row, do: DateTime.to_iso8601(row.updated_at), else: nil),
      "seats" =>
        Enum.map(seats, fn seat ->
          agent = Ash.get!(Agent, seat["agent_id"], not_found_error?: false)
          scope = SeatScope.public(SeatScope.get(seat["agent_id"]), seat["agent_id"])

          Map.merge(seat, %{
            "scope" => scope,
            "current_scope_revision" => scope["revision"],
            "observed_model" => if(agent, do: agent.model, else: nil),
            "observed_retired_at" =>
              if(agent && agent.retired_at, do: DateTime.to_iso8601(agent.retired_at), else: nil)
          })
        end)
    }
  end

  def validate(data) when is_map(data) do
    with true <- exact_keys?(data, ~w(revision idempotency_key seats)),
         true <- is_integer(data["revision"]) and data["revision"] in 0..2_147_483_646,
         true <- bounded?(data["idempotency_key"], 128),
         true <- is_list(data["seats"]) and length(data["seats"]) <= 32,
         true <- Enum.all?(data["seats"], &valid_seat?/1),
         true <- unique?(data["seats"], "seat_id") and unique?(data["seats"], "agent_id") do
      seats =
        data["seats"]
        |> Enum.map(fn seat ->
          seat
          |> Map.update!("desired_model", &String.trim/1)
          |> Map.update!("desired_effort", &String.trim/1)
        end)
        |> Enum.sort_by(& &1["seat_id"])

      {:ok, %{data | "seats" => seats, "idempotency_key" => String.trim(data["idempotency_key"])}}
    else
      _ -> invalid()
    end
  end

  def validate(_), do: invalid()

  defp valid_seat?(seat) when is_map(seat) do
    exact_keys?(seat, @seat_fields) and
      Enum.all?(~w(seat_id agent_id desired_host_id), &slug?(seat[&1])) and
      bounded?(seat["harness"], 128) and seat["harness"] == String.trim(seat["harness"]) and
      bounded?(seat["desired_model"], 256) and bounded?(seat["desired_effort"], 64) and
      is_integer(seat["scope_revision"]) and seat["scope_revision"] in 1..2_147_483_647
  end

  defp valid_seat?(_), do: false

  defp bounded?(value, max),
    do:
      is_binary(value) and String.valid?(value) and
        byte_size(value) <= max and String.trim(value) != "" and
        not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value)

  defp unique?(seats, key), do: length(Enum.uniq_by(seats, & &1[key])) == length(seats)
  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp digest(parts),
    do: :crypto.hash(:sha256, Jason.encode!(parts)) |> Base.encode16(case: :lower)

  defp authority(capability),
    do:
      if(Captain.authorized?(capability),
        do: :ok,
        else: {:error, "forbidden", "Verified captain capability required"}
      )

  defp slug?(value),
    do:
      is_binary(value) and String.valid?(value) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/, value)

  defp fleet_id(id),
    do: if(slug?(id), do: :ok, else: {:error, "invalid_input", "Valid fleet ID required"})

  defp invalid,
    do:
      {:error, "invalid_input",
       "Full replacement requires bounded revision and idempotency_key, and up to 32 unique seats with explicit identity, harness, desired host/model/effort and managed scope revision; unknown fields are forbidden"}
end
