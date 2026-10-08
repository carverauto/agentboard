defmodule AgentboardWeb.DecisionPanel do
  use Phoenix.Component
  attr(:records, :list, required: true)
  attr(:answered, :list, default: [])
  attr(:total, :any, default: nil)
  attr(:answered_total, :any, default: nil)
  attr(:captain, :any, required: true)
  attr(:unavailable, :boolean, required: true)

  def waiting(assigns) do
    {answered, open} = Enum.split_with(assigns.records, &(&1["status"] == "answered"))

    assigns =
      assigns
      |> assign(:open, open)
      |> assign(:answers, assigns.answered ++ answered)
      |> assign(:count, assigns.total || length(open))
      |> assign(:answer_count, assigns.answered_total || length(assigns.answered ++ answered))

    ~H"""
    <section id="captain-waiting" aria-label="Waiting on captain" class="my-6 min-w-0">
      <h2>Waiting on captain <span class="count">{if @unavailable, do: "?", else: @count}</span></h2>
      <p class="text-muted">Oldest first. Formal decisions hold claims; unfiled asks are read only.</p>
      <p :if={@unavailable} role="alert" class="notice danger">Decision records unavailable; count and freshness are unknown. Showing last known rows.</p>
      <p :if={@count == 0 and not @unavailable} class="empty">No outstanding captain decisions.</p>
      <div class="grid grid-cols-1 gap-4 min-w-0">
        <.row :for={r <- @open} r={r} captain={@captain} />
      </div>
      <details :if={@answer_count > 0} class="mt-4 min-w-0">
        <summary>Answered · awaiting seat ack · {@answer_count}</summary>
        <p class="text-muted">These are excluded from the waiting count; claims remain held until acknowledgement or audited recovery. Up to 20 oldest shown.</p>
        <.row :for={r <- @answers} r={r} captain={@captain} />
      </details>
    </section>
    """
  end

  attr(:r, :map, required: true)
  attr(:captain, :any, required: true)

  def row(assigns) do
    ~H"""
    <article class="task-card min-w-0 mt-3">
      <div class="flex flex-wrap gap-2 items-center">
        <span class="flag">{case @r["status"] do
          "unfiled" -> "Needs captain (no decision filed)"
          "answered" -> "Answered · awaiting seat"
          _ -> "Open · waiting on captain"
        end}</span>
        <span :if={@r["requester_stale"]} class="flag warning">requester_stale · explicit recovery required</span>
        <span :if={@r["held_by_decision"]} class="flag">Claim held by decision</span>
      </div>
      <h3><a href={"/tasks/" <> @r["task_id"]}>{@r["task_id"]}</a></h3>
      <p class="break-all">Seat <a href={"/agents?id=" <> @r["requester_id"]}>{@r["requester_id"]}</a> · {@r["kind"]}</p>
      <p :if={@r["gate_ref"]} class="break-all">Gate {@r["gate_ref"]} · decision {@r["id"]}</p>
      <p>Waiting {AgentboardWeb.RelativeTime.age(@r["created_at"])} · lease timestamp {@r["claim_expires_at"] || "none"}</p>
      <a :if={@r["pr_url"]} href={@r["pr_url"]} target="_blank" rel="noopener noreferrer">Pull request</a>
      <pre class="whitespace-pre-wrap break-all max-h-80 overflow-auto min-w-0 mt-3">{@r["question"]}</pre>
      <details id={"decision-findings-#{@r["id"]}"} phx-hook="CompletedCard" class="mt-3 min-w-0">
        <summary>Verbatim findings</summary>
        <pre class="whitespace-pre-wrap break-all max-h-96 overflow-auto min-w-0">{@r["findings"]}</pre>
      </details>
      <ul :if={@r["options"] != []} class="list-disc pl-5">
        <li :for={option <- @r["options"]} class="break-all">{option}</li>
      </ul>
      <div :if={@r["recommendation"]} class="mt-3">
        <p>Recommendation · {@r["recommended_by"]}</p>
        <pre class="whitespace-pre-wrap break-all max-h-80 overflow-auto">{@r["recommendation"]}</pre>
      </div>
      <div :if={@r["answer"]} class="mt-3">
        <p>Captain answer · {@r["answered_by"]} · {@r["answered_at"]}</p>
        <pre class="whitespace-pre-wrap break-all max-h-80 overflow-auto">{@r["answer"]}</pre>
      </div>
      <form :if={Agentboard.Captain.authorized?(@captain) and @r["status"] == "open"} phx-submit="decision_answer" class="settings-form min-w-0">
        <input type="hidden" name="decision_id" value={@r["id"]} />
        <label>Captain answer<textarea name="answer" required maxlength="8192" class="w-full bg-canvas text-ink border border-line p-2 rounded-md"></textarea></label>
        <button type="submit">Answer decision</button>
      </form>
      <form :if={Agentboard.Captain.authorized?(@captain) and @r["status"] != "unfiled"} phx-submit="decision_supersede" class="settings-form min-w-0">
        <input type="hidden" name="decision_id" value={@r["id"]} />
        <label>Recovery reason<input name="reason" required maxlength="8192" /></label>
        <button type="submit">Supersede all outstanding decisions on this task</button>
      </form>
      <form :if={Agentboard.Captain.authorized?(@captain) and @r["status"] == "unfiled"} phx-submit="decision_promote" class="settings-form min-w-0">
        <input type="hidden" name="task" value={@r["task_id"]} />
        <input type="hidden" name="source_type" value={@r["source_type"]} />
        <input type="hidden" name="source_id" value={@r["source_id"]} />
        <input type="hidden" name="revision" value={@r["revision"]} />
        <label>Explicit captain question<textarea name="question" required maxlength="8192" class="w-full bg-canvas text-ink border border-line p-2 rounded-md">{@r["question"]}</textarea></label>
        <label>Kind<select name="kind" class="w-full bg-canvas text-ink border border-line p-2 rounded-md"><option value="approval" selected>approval</option><option value="merge">merge</option><option value="policy">policy</option><option value="credential">credential</option><option value="scope">scope</option><option value="blocked_decision">blocked_decision</option><option value="other">other</option></select></label>
        <label>Choices, one per line, optional<textarea name="options" maxlength="8192" class="w-full bg-canvas text-ink border border-line p-2 rounded-md"></textarea></label>

        <button type="submit">Promote owner ask to decision</button>
      </form>
    </article>
    """
  end
end
