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
        <dt>Conflicting files</dt><dd>Unknown</dd>
        <dt>Disposition</dt><dd class="min-w-0 break-all">{@projection.order["selection_reason"] || "Not recorded"}</dd>
        <dt>Delivery</dt><dd>{@projection.source_mode}</dd>
        <dt>Publication admission</dt><dd>Unavailable · native custody is not verified</dd>
      </dl>
      <div :if={@projection.escalation} class="min-w-0">
        <p class="flag warning">Captain escalation · {@projection.escalation["status"]}</p>
        <p class="break-all">Decision {@projection.escalation["id"]} · {@projection.escalation["gate_ref"]}</p>
        <p class="whitespace-pre-wrap break-all">{@projection.escalation["question"]}</p>
        <p :if={@projection.escalation["close_reason"]} class="whitespace-pre-wrap break-all">{@projection.escalation["close_reason"]}</p>
      </div>
      <details id={"conflict-history-" <> @projection.order["pull_request_id"]} phx-hook="CompletedCard" class="min-w-0">
        <summary>Order history · 20 most recent</summary>
        <ol class="list-decimal pl-5 min-w-0">
          <li :for={row <- @projection.history} class="my-3 min-w-0">
            <p class="break-all">Revision {row["revision"]} · {row["state"]} · {row["id"]}</p>
            <p class="break-all">Recipient {row["recipient_id"] || "Captain queue"} · {row["selection_reason"] || "Not recorded"}</p>
            <p class="break-all">Default {row["default_ref"]}@{row["default_tip_sha"]}</p>
            <p class="break-all">Target {row["evaluation_base_ref"]}@{row["evaluation_base_sha"]}</p>
          </li>
        </ol>
      </details>
    </section>
    """
  end
end
