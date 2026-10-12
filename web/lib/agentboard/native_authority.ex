defmodule Agentboard.NativeAuthority do
  @moduledoc "Captain-approved immutable inventory and bounded host reads. Native activation is separately default-off."
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Cooperation.{Binding, NativeApproval, Subscription}
  alias Agentboard.Cooperation.Runtime
  alias Agentboard.NativeAuthority.Manifest
  require Ash.Query

  @captain %{
    "agent" => "captain",
    "model" => "human",
    "harness" => "captain",
    :native_authority_admin => true
  }
  @system %{"agent" => "cooperation", "model" => "system", "harness" => "ash"}

  def approve(id, data) do
    if Agentboard.Input.slug?(id) and
         Manifest.exact?(data, ~w(expected_authority_revision manifest idempotency_key)) and
         Manifest.safe?(data["expected_authority_revision"]) and key?(data["idempotency_key"]) and
         Manifest.valid?(data["manifest"]) do
      Ops.transaction(fn ->
        Agentboard.Availability.lock_admission()
        Runtime.lock_worker(id)
        s = Ops.fetch!(Subscription, id, "Worker not enrolled")
        b = Ops.fetch!(Binding, id, "Worker binding not found")
        digest = Manifest.sha256(data["manifest"])

        prior =
          NativeApproval
          |> Ash.Query.filter(worker_id == ^id and idempotency_key == ^data["idempotency_key"])
          |> Ash.read_one!()

        if prior do
          unless prior.expected_authority_revision == data["expected_authority_revision"] and
                   prior.manifest_sha256 == digest and prior.manifest == data["manifest"] and
                   b.native_authority_revision == prior.authority_revision and
                   b.native_approval_id == prior.id,
                 do:
                   Ops.reject("conflict", "Approval retry differs or authority has since changed")

          envelope(s, b, true)
        else
          unless b.native_authority_revision == data["expected_authority_revision"],
            do: Ops.reject("conflict", "Native authority revision changed")

          unless descriptor_matches?(data["manifest"], s, b),
            do: Ops.reject("conflict", "Manifest does not match current enrollment and binding")

          unless current_reasons(s, b) == [],
            do: Ops.reject("conflict", "Current worker is not eligible for native approval")

          if Ash.get!(NativeApproval, data["manifest"]["id"], not_found_error?: false),
            do: Ops.reject("conflict", "Approval ID is immutable and already exists")

          attrs = advance(b, false)

          approval =
            Ops.create(
              NativeApproval,
              :record,
              %{
                id: data["manifest"]["id"],
                worker_id: id,
                expected_authority_revision: b.native_authority_revision,
                authority_revision: attrs.native_authority_revision,
                idempotency_key: data["idempotency_key"],
                manifest: data["manifest"],
                manifest_sha256: digest,
                approved_by: "captain",
                approved_at: Ops.now()
              },
              @captain
            )

          changed =
            Ops.update(b, :change, Map.put(attrs, :native_approval_id, approval.id), @captain)

          envelope(s, changed, false)
        end
      end)
    else
      {:error, "invalid_input",
       "Exact bounded manifest, expected authority revision and idempotency key required"}
    end
  end

  def retire(id, data) do
    if Agentboard.Input.slug?(id) and
         Manifest.exact?(data, ~w(expected_authority_revision idempotency_key)) and
         Manifest.safe?(data["expected_authority_revision"]) and key?(data["idempotency_key"]) do
      Ops.transaction(fn ->
        Agentboard.Availability.lock_admission()
        Runtime.lock_worker(id)
        s = Ops.fetch!(Subscription, id, "Worker not enrolled")
        b = Ops.fetch!(Binding, id, "Worker binding not found")

        if b.native_retire_key == data["idempotency_key"] do
          unless b.native_retire_expected_revision == data["expected_authority_revision"] and
                   b.native_retire_revision == b.native_authority_revision and
                   is_nil(b.native_approval_id),
                 do:
                   Ops.reject(
                     "conflict",
                     "Retirement retry differs or authority has since changed"
                   )

          envelope(s, b, true)
        else
          unless b.native_authority_revision == data["expected_authority_revision"],
            do: Ops.reject("conflict", "Native authority revision changed")

          # No pointer means no authority transition. Record this no-op's exact
          # CAS target so a lost response can be retried without advancing it.
          attrs =
            if b.native_approval_id,
              do: advance(b),
              else: %{native_authority_revision: b.native_authority_revision}

          attrs =
            Map.merge(attrs, %{
              native_retire_key: data["idempotency_key"],
              native_retire_expected_revision: b.native_authority_revision,
              native_retire_revision: attrs.native_authority_revision,
              updated_at: Ops.now()
            })

          changed = Ops.update(b, :change, attrs, @captain)
          envelope(s, changed, false)
        end
      end)
    else
      {:error, "invalid_input", "Exact expected authority revision and idempotency key required"}
    end
  end

  # Called only with admission then worker custody. This never expires attempts,
  # captures a source, routes deliveries, mints a credential or writes receipts.
  def snapshot(s, b) do
    approval = if b.native_approval_id, do: Ash.get!(NativeApproval, b.native_approval_id)
    reasons = current_reasons(s, b)
    reasons = if approval, do: reasons, else: reasons ++ ["native_approval_missing"]

    reasons =
      if approval && not descriptor_matches?(approval.manifest, s, b),
        do: reasons ++ ["native_approval_stale"],
        else: reasons

    reasons = reason(reasons, not enabled?(), "native_profile_live_disabled")

    %{
      protocol_revision: 1,
      authority_contract_revision: 1,
      worker_id: s.id,
      host_id: s.host_id,
      authority_revision: b.native_authority_revision,
      approval_id: if(approval, do: approval.id),
      manifest_sha256: if(approval, do: approval.manifest_sha256),
      manifest: if(approval, do: approval.manifest),
      enrollment_revision: Agentboard.Wake.Transport.enrollment_revision(s),
      binding_epoch: b.epoch,
      permitted: reasons == [],
      reason_codes: reasons,
      valid_for_ms: if(reasons == [], do: 5000, else: 0)
    }
  end

  def enabled?, do: Application.get_env(:agentboard, :native_authority_enabled, false) == true

  def advance(b, clear? \\ true) do
    next = b.native_authority_revision + 1
    unless Manifest.safe?(next), do: Ops.reject("conflict", "Native authority revision exhausted")
    attrs = %{native_authority_revision: next, updated_at: Ops.now()}
    if clear?, do: Map.put(attrs, :native_approval_id, nil), else: attrs
  end

  def invalidate(b), do: Ops.update(b, :change, advance(b), @system)

  defp descriptor_matches?(m, s, b) do
    m["worker_id"] == s.id and m["host_id"] == s.host_id and
      m["enrollment_revision"] == Agentboard.Wake.Transport.enrollment_revision(s) and
      m["binding_epoch"] == b.epoch and m["session_id"] == b.session_id and
      m["pane_id"] == b.pane_id
  end

  defp current_reasons(s, b) do
    agent = Agentboard.Availability.admission_agent(s.id)
    scope = Agentboard.SeatScope.get(s.id)

    []
    |> reason(s.revoked, "enrollment_revoked")
    |> reason(s.paused, "paused")
    |> reason(not Runtime.enabled?(s), "cooperation_disabled")
    |> reason(is_nil(b.session_id) or is_nil(b.pane_id) or b.epoch <= 0, "unbound")
    |> reason(
      s.harness != "codex" or b.adapter != "codex-app-server-v1",
      "native_binding_unsupported"
    )
    |> reason(agent.model != s.model or agent.harness != s.harness, "enrollment_identity_stale")
    |> reason(
      not is_nil(agent.retired_at) or not Agentboard.Availability.active?(agent),
      "agent_unavailable"
    )
    |> reason(
      not is_nil(scope) and not Enum.all?(s.repos, &(&1 in scope.allowed_repos)),
      "seat_scope_changed"
    )
  end

  defp envelope(s, b, idempotent),
    do: %{authority_contract_revision: 1, authority: snapshot(s, b), idempotent: idempotent}

  defp reason(reasons, true, code), do: reasons ++ [code]
  defp reason(reasons, _, _), do: reasons
  defp key?(s), do: is_binary(s) and Regex.match?(~r/\A[\x21-\x7e]{1,128}\z/, s)
end
