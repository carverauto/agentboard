defmodule Agentboard.Delivery.ConflictPolicy do
  @moduledoc "Conflict rollout policy is separate from ordinary provider observation."

  def mode do
    case Application.get_env(:agentboard, :conflict_routing_mode, "disabled") do
      mode when mode in ~w(disabled dry_run apply) -> mode
      _ -> "disabled"
    end
  end

  def deadline_seconds do
    case Application.get_env(:agentboard, :conflict_deadline_seconds, 2700) do
      seconds when is_integer(seconds) and seconds in 60..86400 -> seconds
      _ -> 2700
    end
  end

  # One classification for legacy repair, current orders and dry-run evidence.
  def observation_state(result) do
    cond do
      result.lifecycle != "open" ->
        :closed

      result.payload["mergeable"] == true and result.payload["mergeable_state"] != "dirty" ->
        :clean

      result.payload["mergeable"] == false and result.payload["mergeable_state"] == "dirty" ->
        :dirty

      true ->
        :unknown
    end
  end

  def observe_defaults?, do: mode() != "disabled"
end
