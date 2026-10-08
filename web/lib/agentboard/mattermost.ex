defmodule Agentboard.Mattermost do
  @moduledoc "Outbound task-thread bridge. Board mutations commit first; chat delivery follows asynchronously and never gates them."
  use Ash.Domain, backwards_compatible_interface?: false, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(Agentboard.Mattermost.Outbox)
    resource(Agentboard.Mattermost.TaskThread)
    resource(Agentboard.Mattermost.Router)
    resource(Agentboard.Mattermost.ConversationCoverage)
    resource(Agentboard.Mattermost.AgentBot)
  end

  defdelegate enabled?, to: Agentboard.Mattermost.Bridge
end
