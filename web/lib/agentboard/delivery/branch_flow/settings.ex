defmodule Agentboard.Delivery.BranchFlow.Settings do
  @moduledoc "Captain-owned ordered display pins. Never enrolls repositories or changes workflow intake."
  alias Agentboard.{Captain, Repo, SeatScope}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Delivery.BranchFlow.{Configuration, Inventory, Receipt}

  @id "branch-flow"
  @lock 1_853_001
  @actor %{
    "agent" => "captain",
    "model" => "human",
    "harness" => "captain",
    :branch_flow_admin => true
  }

  def show(capability) do
    with :ok <- authority(capability) do
      Ops.transaction(fn ->
        # Serialize even the initially absent row without creating defaults.
        lock(:shared)
        authorize!(capability)
        current = read()
        %{"settings" => current, "availability" => availability(current)}
      end)
    end
  end

  # This is deliberately usable by the read-only branch projection inside its
  # existing repeatable-read snapshot. Failure must not masquerade as empty pins.
  def read do
    unless Repo.in_transaction?(),
      do: Ops.reject("conflict", "Branch-flow settings require a read transaction")

    # A bounded raw read preserves the caller's optional-section savepoint.
    # Ash read error handling can roll back the outer transaction, which would
    # otherwise hide unrelated attention when only settings are unavailable.
    %{rows: rows} =
      Repo.statement!(
        "SELECT revision,pinned_repositories,changed_by,updated_at FROM branch_flow_configuration WHERE id=$1",
        [@id]
      )

    case rows do
      [] ->
        public(nil)

      [[revision, pins, actor, stamp]] ->
        public(%{
          revision: revision,
          pinned_repositories: pins,
          changed_by: actor,
          updated_at: stamp
        })
    end
  end

  def replace(capability, data) do
    with :ok <- authority(capability), {:ok, request} <- validate(data) do
      Ops.transaction(fn ->
        lock(:exclusive)
        authorize!(capability)
        receipt_id = receipt_id(request)

        case Ash.get!(Receipt, receipt_id, not_found_error?: false) do
          nil -> replace_locked(capability, request, receipt_id)
          receipt -> replay!(receipt, request)
        end
      end)
    end
  end

  # The writer lock prevents an absent receipt being mistaken for a safe retry
  # while another request is still committing. This operation never writes.
  def reconcile(capability, data) do
    with :ok <- authority(capability), {:ok, request} <- validate(data) do
      Ops.transaction(fn ->
        lock(:exclusive)
        authorize!(capability)
        current = read()
        receipt = Ash.get!(Receipt, receipt_id(request), not_found_error?: false)

        {status, committed} =
          if receipt do
            replay = replay!(receipt, request)
            {"committed", replay["settings"]}
          else
            status =
              if current["revision"] == request["revision"], do: "retry_safe", else: "conflict"

            {status, nil}
          end

        %{
          "status" => status,
          "settings" => current,
          "committed_settings" => committed,
          "availability" => availability(current),
          "replayed" => not is_nil(receipt)
        }
      end)
    end
  end

  defp replace_locked(capability, request, receipt_id) do
    prior = Ash.get!(Configuration, @id, not_found_error?: false)
    revision = if prior, do: prior.revision, else: 0

    if revision != request["revision"],
      do: Ops.reject("conflict", "Branch-flow settings revision changed; reload explicitly")

    pins = request["pinned_repositories"]
    eligible = Inventory.present(pins)
    unavailable = Enum.reject(pins, &(&1 in eligible))

    if unavailable != [],
      do:
        Ops.reject(
          "invalid_input",
          "pinned_repositories contains unavailable tracked repositories: " <>
            Enum.join(unavailable, ", ") <> "; remove unavailable pins explicitly"
        )

    attrs = %{
      pinned_repositories: pins,
      revision: revision + 1,
      changed_by: "captain",
      updated_at: Ops.now()
    }

    # Proof is server-held and checked again after all potentially blocking reads.
    # Neither a client actor field nor a pre-lock authorization grants this write.
    authorize!(capability)

    row =
      if prior,
        do: Ops.update(prior, :replace, attrs, @actor, revision),
        else: Ops.create(Configuration, :record, Map.put(attrs, :id, @id), @actor)

    response = %{"settings" => public(row), "replayed" => false}

    Ops.create(
      Receipt,
      :record,
      %{
        id: receipt_id,
        configuration_id: @id,
        idempotency_key: request["idempotency_key"],
        request: request,
        response: response,
        created_at: attrs.updated_at
      },
      @actor
    )

    # An audit hook or database constraint may itself wait. Expiry during those
    # writes rolls the entire configuration/history/receipt transaction back.
    authorize!(capability)
    response
  end

  defp replay!(receipt, request) do
    if receipt.request != request,
      do: Ops.reject("conflict", "Idempotency key was used for a different settings replacement")

    Map.put(receipt.response, "replayed", true)
  end

  defp availability(settings) do
    pins = settings["pinned_repositories"]
    eligible = Inventory.present(pins)
    Map.new(pins, &{&1, &1 in eligible})
  end

  defp public(nil),
    do: %{
      "revision" => 0,
      "pinned_repositories" => [],
      "changed_by" => nil,
      "updated_at" => nil
    }

  defp public(row),
    do: %{
      "revision" => row.revision,
      "pinned_repositories" => row.pinned_repositories,
      "changed_by" => row.changed_by,
      "updated_at" => DateTime.to_iso8601(row.updated_at)
    }

  def validate(data) when is_map(data) do
    cond do
      Enum.sort(Map.keys(data)) != ~w(idempotency_key pinned_repositories revision) ->
        invalid("Exact revision, idempotency_key and pinned_repositories fields required")

      not (is_integer(data["revision"]) and data["revision"] in 0..2_147_483_646) ->
        invalid("revision must be a nonnegative bounded integer")

      not valid_key?(data["idempotency_key"]) ->
        invalid("idempotency_key must be 1–128 bytes without padding or control characters")

      not is_list(data["pinned_repositories"]) ->
        invalid("pinned_repositories must be an ordered list")

      length(data["pinned_repositories"]) > 5 ->
        invalid("pinned_repositories permits at most five repositories")

      not Enum.all?(data["pinned_repositories"], &canonical?/1) ->
        invalid("pinned_repositories requires exact lowercase canonical owner/repo identities")

      Enum.uniq(data["pinned_repositories"]) != data["pinned_repositories"] ->
        invalid("pinned_repositories must contain unique repositories")

      true ->
        {:ok, data}
    end
  end

  def validate(_), do: invalid("Exact settings replacement object required")

  defp canonical?(repo),
    do: is_binary(repo) and String.valid?(repo) and SeatScope.canonical_repo(repo) == repo

  defp valid_key?(key),
    do:
      is_binary(key) and String.valid?(key) and byte_size(key) in 1..128 and
        String.trim(key) == key and not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, key)

  defp receipt_id(request),
    do:
      :crypto.hash(:sha256, Jason.encode!([@id, request["idempotency_key"]]))
      |> Base.encode16(case: :lower)

  defp lock(:shared), do: Repo.statement!("SELECT pg_advisory_xact_lock_shared($1)", [@lock])
  defp lock(:exclusive), do: Repo.statement!("SELECT pg_advisory_xact_lock($1)", [@lock])

  defp authorize!(capability) do
    unless Captain.authorized?(capability),
      do: Ops.reject("forbidden", "Verified current captain capability required")
  end

  defp authority(capability),
    do:
      if(Captain.authorized?(capability),
        do: :ok,
        else: {:error, "forbidden", "Verified current captain capability required"}
      )

  defp invalid(message), do: {:error, "invalid_input", message}
end
