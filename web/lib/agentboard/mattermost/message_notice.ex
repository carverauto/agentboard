defmodule Agentboard.Mattermost.MessageNotice do
  @moduledoc "Dual-mode source capture; private notices never fall back to public threads."
  alias Agentboard.Mattermost.Bridge

  # The handoff's internal board message is represented by its task-event
  # intent, not a second chat echo. Ordinary sends have one intent per row.
  def capture(message, actor, stamp) do
    if Agentboard.MessageMode.dual?() do
      private? = is_binary(message.recipient_id)

      destination =
        if private?,
          do: "mattermost:agent_inbox:" <> message.recipient_id,
          else: "mattermost:board_thread:" <> message.task_id

      Bridge.capture_intent(
        %{
          source: "board_message",
          source_key: "message:#{message.id}",
          task_id: message.task_id,
          destination: destination,
          event_marker: "agentboard:message:#{message.id}:notice",
          last_error: if(private?, do: "recipient_route_unavailable", else: nil),
          payload: %{
            "action" => "message",
            "message_id" => message.id,
            "recipient" => message.recipient_id,
            # Private notices retain a source reference, never a public echo.
            "note" => if(private?, do: nil, else: Bridge.note_snippet(message.body)),
            "actor" => actor["agent"],
            "model" => actor["model"],
            "harness" => actor["harness"]
          }
        },
        stamp
      )
    else
      {:ok, :disabled}
    end
  end
end
