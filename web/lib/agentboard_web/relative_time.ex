defmodule AgentboardWeb.RelativeTime do
  @moduledoc "Display elapsed time: seconds below 90, then whole minutes, hours and days."

  def age(stamp, now \\ DateTime.utc_now())

  def age(stamp, now) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, time, _} -> elapsed(max(0, DateTime.diff(now, time)))
      _ -> "Unknown age"
    end
  end

  def age(_, _), do: "Unknown age"

  defp elapsed(0), do: "Just now"
  defp elapsed(seconds) when seconds < 90, do: "#{seconds}s ago"
  defp elapsed(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp elapsed(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h ago"
  defp elapsed(seconds), do: "#{div(seconds, 86_400)}d ago"
end
