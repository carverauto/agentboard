defmodule Agentboard.Delivery.ConflictPolicy do
  @moduledoc "Conflict rollout policy is separate from ordinary provider observation."

  def mode do
    case Application.get_env(:agentboard, :conflict_routing_mode, "disabled") do
      mode when mode in ~w(disabled dry_run apply) -> mode
      _ -> "disabled"
    end
  end

  def observe_defaults?, do: mode() != "disabled"
end
