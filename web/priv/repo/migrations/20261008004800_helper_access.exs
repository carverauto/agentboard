defmodule Agentboard.Repo.Migrations.HelperAccess do
  use Ecto.Migration

  # Schema 48: helper identity kind and narrow helper credential scope.
  def up do
    drop(constraint(:agents, :agent_kind))

    create(
      constraint(:agents, :agent_kind,
        check: "kind IN ('seat','human','system','fixture','helper')"
      )
    )

    drop(constraint(:agent_api_credentials, :agent_credential_scope))

    create(
      constraint(:agent_api_credentials, :agent_credential_scope,
        check:
          "scope IN ('agent','coordinator','coordinator_participant','coordinator_runner','helper','system','captain-admin')"
      )
    )

    execute("UPDATE board_schema SET version=GREATEST(version,48) WHERE id=1")
  end

  def down, do: raise("Retain helper identity and credential evidence; use compatible code")
end
