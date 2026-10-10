defmodule Agentboard.Auth.APIAuthPolicy do
  @moduledoc "Explicit API capability boundaries. HTTP method alone never establishes read-only access."

  alias AgentboardWeb.{
    APIController,
    CaptainController,
    AgentTokenController,
    ConversationController,
    CoordinatorController,
    DecisionController,
    DecisionConversationController,
    MetaController,
    WatchController,
    WorkerController,
    WorkflowHookController
  }

  @system_ids ~w(ci-accountability cooperation system housekeeping delivery delivery-observation
    delivery-discovery delivery-polling pr-observation captain auth-system availability-expiry decision-maintenance
    mattermost-bridge mattermost-conversations mattermost-elastic-bots)

  def reserved?(id, harness, kind \\ nil) do
    not Agentboard.Input.slug?(id) or harness in ~w(ash system server captain) or
      kind == "system" or id in @system_ids or String.starts_with?(id, "system-")
  end

  def credential_allowed?(credential, agent, coordinator) when is_map(agent) do
    is_nil(credential.revoked_at) and is_nil(agent.retired_at) and
      not reserved?(agent.id, agent.harness, agent.kind) and
      credential.agent_id == agent.id and
      case credential.scope do
        "agent" ->
          agent.id != coordinator

        "coordinator" ->
          is_binary(coordinator) and agent.id == coordinator

        "coordinator_participant" ->
          is_binary(coordinator) and agent.id == coordinator and
            valid_channel_grant?(credential.scope, Map.get(credential, :channel_ids))

        "coordinator_runner" ->
          is_binary(coordinator) and agent.id == coordinator and
            valid_channel_grant?(credential.scope, Map.get(credential, :channel_ids))

        _ ->
          false
      end
  end

  def credential_allowed?(_, _, _), do: false

  def valid_channel_grant?("coordinator_participant", channel_ids) when is_list(channel_ids) do
    length(channel_ids) in 1..20 and
      length(Enum.uniq(channel_ids)) == length(channel_ids) and
      Enum.all?(channel_ids, &channel_id?/1)
  end

  def valid_channel_grant?(scope, []), do: scope in ~w(agent coordinator coordinator_runner)
  def valid_channel_grant?(_, _), do: false

  def channel_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  def boundary(%{plug: MetaController, plug_opts: :show}), do: :public
  def boundary(%{plug: WorkflowHookController, plug_opts: :create}), do: :independent

  def boundary(%{plug: WorkerController, plug_opts: action})
      when action in [:provision, :resolve_attempt, :responsibility, :revoke, :operate],
      do: :independent

  def boundary(%{plug: AgentboardWeb.CoordinatorTriageController}), do: :captain

  def boundary(%{plug: AgentboardWeb.FleetLoadoutController}), do: :captain

  def boundary(%{plug: CaptainController, plug_opts: action})
      when action in [:settings, :save, :archive, :restore], do: :captain

  def boundary(%{plug: AgentTokenController, plug_opts: action})
      when action in [:list, :mutate, :report], do: :captain

  def boundary(%{plug: controller})
      when controller in [
             APIController,
             ConversationController,
             CoordinatorController,
             DecisionController,
             DecisionConversationController,
             WatchController
           ],
      do: :agent

  def boundary(_), do: :deny

  # These operations already require a separately verified captain capability
  # downstream. This list does not promote an agent or coordinator credential.
  def captain_operation?(%{plug: APIController, plug_opts: action}, _params)
      when action in [:set_availability, :set_seat_scope, :broadcast_orders, :retire, :restore],
      do: true

  def captain_operation?(%{plug: APIController, plug_opts: :mutate}, params),
    do: params["action"] in ~w(assign handoff)

  def captain_operation?(%{plug: DecisionController, plug_opts: :promote}, _), do: true

  def captain_operation?(%{plug: DecisionController, plug_opts: :mutate}, params),
    do: params["action"] in ~w(recommend answer supersede)

  def captain_operation?(%{plug: DecisionController, plug_opts: :wake_mutate}, params),
    do: params["action"] in ~w(reserve accept uncertain skip)

  # Admin bootstrap needs a read-before-write without possessing the new agent's token.
  def captain_operation?(%{plug: APIController, plug_opts: action}, _)
      when action in [:agent, :availability, :seat_scope], do: true

  def captain_operation?(_, _), do: false

  def bootstrap?(%{plug: APIController, plug_opts: :register}), do: true
  def bootstrap?(_), do: false

  # Must precede the ordinary-agent catch-all. This surface is an independent,
  # explicitly issued capability, not an ordinary board write.
  def allowed?(principal, %{plug: CoordinatorController, plug_opts: action}, method, _) do
    principal[:scope] == "coordinator_runner" and
      ((action in [:tick, :show] and method in ["GET", "HEAD"]) or
         (action in [:ack, :heartbeat] and method == "POST"))
  end

  def allowed?(
        %{scope: "agent"},
        %{plug: DecisionConversationController, plug_opts: action},
        method,
        _
      ) do
    (action == :notify and method == "POST") or
      (action == :show and method in ["GET", "HEAD"]) or
      (action == :reconcile and method == "POST")
  end

  def allowed?(%{scope: "agent"}, _info, _method, _params), do: true

  def allowed?(
        %{scope: "coordinator_participant", agent_id: id} = principal,
        info,
        method,
        params
      ) do
    valid_channel_grant?(principal.scope, Map.get(principal, :channel_ids)) and
      (participant_operation?(info, method) or
         allowed?(%{scope: "coordinator", agent_id: id}, info, method, params))
  end

  def allowed?(%{scope: "coordinator", agent_id: id}, info, method, params)
      when method in ["GET", "HEAD"] do
    case info do
      %{plug: APIController, plug_opts: action}
      when action in [:tasks, :task, :prs, :pr, :agents, :agent, :seat_scope] ->
        true

      %{plug: APIController, plug_opts: action} when action in [:message, :message_triage] ->
        true

      %{plug: DecisionController, plug_opts: action}
      when action in [:index, :show, :waiting, :wakes] ->
        true

      %{plug: WatchController, plug_opts: :tasks} ->
        true

      %{plug: controller, plug_opts: :messages}
      when controller in [APIController, WatchController] ->
        not Map.has_key?(params, "task") and Map.get(params, "to", id) == id

      _ ->
        false
    end
  end

  def allowed?(_, _, _, _), do: false

  # Path identity, exact recipient and channel checks are enforced in controllers.
  # The auth plug's params are query-only, so they cannot authorize path targets.
  defp participant_operation?(%{plug: APIController, plug_opts: action}, "POST")
       when action in [:heartbeat, :read_message], do: true

  defp participant_operation?(%{plug: ConversationController, plug_opts: action}, method)
       when action in [:reads, :coverage, :diagnostics] and method in ["GET", "HEAD"], do: true

  defp participant_operation?(%{plug: ConversationController, plug_opts: action}, "POST")
       when action in [:send, :report_coverage], do: true

  defp participant_operation?(%{plug: DecisionConversationController, plug_opts: :show}, method)
       when method in ["GET", "HEAD"], do: true

  defp participant_operation?(%{plug: DecisionConversationController, plug_opts: action}, "POST")
       when action in [:reply, :reconcile], do: true

  defp participant_operation?(_, _), do: false
end
