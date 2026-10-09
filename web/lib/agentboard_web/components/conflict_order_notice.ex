defmodule AgentboardWeb.ConflictOrderNotice do
  @moduledoc "Retained conflict evidence shared by task and PR views."
  use Phoenix.Component

  attr(:projection, :map, default: nil)
  attr(:unavailable, :boolean, default: false)

  def notice(assigns) do
    ~H"""
    <section :if={@projection} class="task-detail min-w-0" aria-label="Conflict repair order">
      <h3>Conflict repair</h3>
      <p :if={@unavailable} class="flag warning">Order evidence is unavailable; retained values are last known.</p>
      <p>Last observed: {@projection.order["state"]} · revision {@projection.order["revision"]}</p>
      <dl class="min-w-0">
        <dt>Repair</dt><dd class="min-w-0 break-all"><a href={"/tasks/" <> @projection.order["repair_task_id"]}>{@projection.order["repair_task_id"]}</a></dd>
        <dt>Repair owner</dt><dd class="min-w-0 break-all">{@projection.repair_owner_id || "Captain queue"}</dd>
        <dt>Author</dt><dd class="min-w-0 break-all">{@projection.order["author_id"] || "Unknown author"}</dd>
        <dt>Deadline</dt><dd class="min-w-0 break-all"><time datetime={@projection.order["deadline_at"]}>{@projection.order["deadline_at"]}</time></dd>
        <dt>Selected recipient</dt><dd class="min-w-0 break-all">{@projection.order["recipient_id"] || "Captain queue"}</dd>
        <dt>Default tip</dt><dd class="min-w-0 break-all">{@projection.order["default_ref"]}@{@projection.order["default_tip_sha"]}</dd>
        <dt>Evaluated target</dt><dd class="min-w-0 break-all">{@projection.order["evaluation_base_ref"]}@{@projection.order["evaluation_base_sha"]}</dd>
        <dt>Rebaser</dt><dd class="min-w-0 break-all">{@projection.order["rebaser_id"] || "Not verified"}</dd>
        <dt>Disposition</dt><dd class="min-w-0 break-all">{@projection.order["selection_reason"] || "Not recorded"}</dd>
        <dt>Delivery</dt><dd>{@projection.source_mode}</dd>
      </dl>
      <p :if={@projection.order["escalation_decision_id"]} class="flag warning">Captain escalation · {@projection.order["escalation_decision_id"]}</p>
    </section>
    """
  end
end
