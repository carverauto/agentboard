defmodule Agentboard.Repo do
  use AshPostgres.Repo, otp_app: :agentboard

  def installed_extensions, do: ["ash-functions"]
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
