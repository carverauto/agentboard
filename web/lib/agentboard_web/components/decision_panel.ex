defmodule AgentboardWeb.DecisionPanel do
  use Phoenix.Component

  def waiting(assigns) do
    ~H"""
    <section aria-label="Waiting on captain" class="mt-8 min-w-0">
      <h2>Waiting on captain</h2>
      <p class="text-muted">Decision holds protect these claims. Stale seats require explicit, audited recovery.</p>
      <p :if={@unavailable} role="alert" class="notice danger">Decision records unavailable; freshness cannot be verified.</p>
      <p :if={@records == [] and not @unavailable} class="empty">No outstanding captain decisions.</p>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 min-w-0">
        <article :for={r <- @records} class="task-card min-w-0">
          <div class="flex flex-wrap gap-2 items-center">
            <span class="flag">{if r["status"] == "answered", do: "Answered · awaiting seat", else: "Open · waiting on captain"}</span>
            <span :if={r["requester_stale"]} class="flag warning">requester_stale · explicit recovery required</span>
            <span :if={r["held_by_decision"]} class="flag">Claim held by decision</span>
          </div>
          <h3><a href={"/tasks/" <> r["task_id"]}>{r["task_id"]}</a></h3>
          <p class="break-all">Seat {r["requester_id"]} · {r["kind"]}</p>
          <p class="break-all">Gate {r["gate_ref"]} · decision {r["id"]}</p>
          <p>Waiting {AgentboardWeb.RelativeTime.age(r["created_at"])} · lease timestamp {r["claim_expires_at"] || "none"}</p>
          <pre class="whitespace-pre-wrap break-all max-h-80 overflow-auto min-w-0 mt-3">{r["question"]}</pre>
          <details id={"decision-findings-#{r["id"]}"} phx-hook="CompletedCard" class="mt-3 min-w-0">
            <summary>Verbatim findings</summary>
            <pre class="whitespace-pre-wrap break-all max-h-96 overflow-auto min-w-0">{r["findings"]}</pre>
          </details>
          <ul :if={r["options"] != []} class="list-disc pl-5">
            <li :for={option <- r["options"]} class="break-all">{option}</li>
          </ul>
          <div :if={r["recommendation"]} class="mt-3">
            <p>Recommendation · {r["recommended_by"]}</p>
            <pre class="whitespace-pre-wrap break-all max-h-80 overflow-auto">{r["recommendation"]}</pre>
          </div>
          <div :if={r["answer"]} class="mt-3">
            <p>Captain answer · {r["answered_by"]} · {r["answered_at"]}</p>
            <pre class="whitespace-pre-wrap break-all max-h-80 overflow-auto">{r["answer"]}</pre>
          </div>
          <form :if={Agentboard.Captain.authorized?(@captain) and r["status"] == "open"} phx-submit="decision_answer" class="settings-form min-w-0">
            <input type="hidden" name="decision_id" value={r["id"]} />
            <label>Captain answer<textarea name="answer" required maxlength="8192" class="w-full bg-canvas text-ink border border-line p-2 rounded-md"></textarea></label>
            <button type="submit">Answer decision</button>
          </form>
          <form :if={Agentboard.Captain.authorized?(@captain)} phx-submit="decision_supersede" class="settings-form min-w-0">
            <input type="hidden" name="decision_id" value={r["id"]} />
            <label>Recovery reason<input name="reason" required maxlength="8192" /></label>
            <button type="submit">Supersede all outstanding decisions on this task</button>
          </form>
        </article>
      </div>
    </section>
    """
  end
end
