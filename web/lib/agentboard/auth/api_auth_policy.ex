defmodule Agentboard.Auth.APIAuthPolicy do
  @moduledoc "Explicit API capability boundaries. HTTP method alone never establishes read-only access."

  alias AgentboardWeb.{
    APIController,
    CaptainController,
    AgentTokenController,
    ConversationController,
    DecisionController,
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
        "agent" -> agent.id != coordinator
        "coordinator" -> is_binary(coordinator) and agent.id == coordinator
        _ -> false
      end
  end

  def credential_allowed?(_, _, _), do: false

  def boundary(%{plug: MetaController, plug_opts: :show}), do: :public
  def boundary(%{plug: WorkflowHookController, plug_opts: :create}), do: :independent

  def boundary(%{plug: WorkerController, plug_opts: action})
      when action in [:provision, :resolve_attempt, :responsibility, :revoke, :operate],
      do: :independent

  def boundary(%{plug: AgentboardWeb.FleetLoadoutController}), do: :captain

  def boundary(%{plug: CaptainController, plug_opts: action})
      when action in [:settings, :save, :archive, :restore], do: :captain

  def boundary(%{plug: AgentTokenController, plug_opts: action})
      when action in [:list, :mutate, :report], do: :captain

  def boundary(%{plug: controller})
      when controller in [
             APIController,
             ConversationController,
             DecisionController,
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

  def allowed?(%{scope: "agent"}, _info, _method, _params), do: true

  def allowed?(%{scope: "coordinator", agent_id: id}, info, method, params)
      when method in ["GET", "HEAD"] do
    case info do
      %{plug: APIController, plug_opts: action}
      when action in [:tasks, :task, :prs, :pr, :agents, :agent, :seat_scope] ->
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
end
