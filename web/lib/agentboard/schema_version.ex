defmodule Agentboard.SchemaVersion do
  @required 3
  def required, do: @required

  def current do
    case Ecto.Adapters.SQL.query(
           Agentboard.Repo,
           "SELECT version FROM board_schema WHERE id = 1",
           [],
           timeout: 2_000,
           queue: false
         ) do
      {:ok, %{rows: [[version]]}} when version >= @required -> {:ok, version}
      _ -> {:error, :unavailable}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end
end

