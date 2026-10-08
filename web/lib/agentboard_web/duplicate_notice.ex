defmodule AgentboardWeb.DuplicateNotice do
  use Phoenix.Component
  attr(:finding, :map, default: nil)
  def notice(assigns) do
    ~H"""
    <aside :if={@finding} class="notice warning min-w-0 break-words" aria-label="Possible duplicate PR">
      <strong>Possible duplicate</strong> of <a href={@finding["merged_url"]} target="_blank" rel="noopener noreferrer">merged original</a>.
      <p>Retained {@finding["basis"]} evidence; owner and captain decide whether this is deliberate follow-up work.</p>
      <details :if={@finding["decision_cta"]}>
        <summary>Owner: request captain decision</summary>
        <p>{@finding["decision_cta"]["owner_id"]} must hold the linked card's claim. This request parks that card; it does not close the PR.</p>
        <code class="block whitespace-normal break-all">{@finding["decision_cta"]["command"]}</code>
      </details>
      <p :if={!@finding["decision_cta"]}>No live duplicate-card owner. Coordinate before requesting a decision.</p>
    </aside>
    """
  end
end
