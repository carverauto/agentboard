defmodule Agentboard.MessageMode do
  @moduledoc """
  Operator-selected conversation transport. Board stays authoritative until
  cutover capabilities have real producers and acceptance evidence. Neither
  the lifecycle bot nor operator-supplied readiness flags prove peer parity.
  """
  alias Agentboard.Mattermost.{Bridge, Delivery}
  require Logger

  # These implementations are not yet present in this release. Replace each
  # blocker with its owning subsystem's measured readiness when it lands;
  # never expose a configuration boolean that bypasses these prerequisites.
  @missing_capabilities [
    "peer_identities_unavailable_5_1",
    "headless_send_read_unavailable_5_2",
    "inbox_catch_up_unavailable_5_3",
    "delivery_adapter_readiness_unverified",
    "coordinator_decision_path_unavailable_80",
    "legacy_unread_disposition_unverified_80"
  ]

  def status do
    requested = Application.get_env(:agentboard, :message_mode, "board")
    blockers = bridge_blockers() ++ @missing_capabilities

    refused =
      requested not in ["board", "dual", "mattermost"] or
        (requested == "mattermost" and blockers != [])

    %{
      requested: requested,
      effective: if(refused, do: "board", else: requested),
      activation_refused: refused,
      cutover_ready: blockers == [],
      blockers:
        if(requested in ["board", "dual", "mattermost"],
          do: blockers,
          else: ["invalid_message_mode" | blockers]
        )
    }
  end

  def dual?, do: Application.get_env(:agentboard, :message_mode, "board") == "dual"

  def report_activation do
    case status() do
      %{activation_refused: true} = status ->
        Logger.warning(
          "Message mode activation refused; board remains primary: #{Enum.join(status.blockers, ", ")}"
        )

      _ ->
        :ok
    end
  end

  defp bridge_blockers do
    if Bridge.enabled?() do
      case Delivery.config() do
        {:ok, _} -> []
        {:error, reason} -> ["bridge_#{reason}"]
      end
    else
      ["bridge_disabled"]
    end
  end
end
