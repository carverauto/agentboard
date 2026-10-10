defmodule Agentboard.Delivery.RepositoryMetadata do
  @moduledoc "Audited provider repository metadata, fenced across workflow collectors by repository generation."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table("delivery_repository_metadata")
    repo(Agentboard.Repo)
  end

  events do
    event_log(Agentboard.Board.AuditEvent)
  end

  actions do
    defaults([:read])

    create :enroll do
      accept([:id])
      upsert?(true)
      upsert_fields([:id])
    end

    update :reserve do
      accept([:generation, :last_error])
    end

    update :observe do
      accept([
        :default_ref,
        :observed_at,
        :source_generation,
        :source_run_id,
        :source_run_generation,
        :last_error
      ])
    end

    update :defer do
      accept([:last_error])
    end
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false)
    attribute(:generation, :integer, allow_nil?: false, default: 0)
    attribute(:source_generation, :integer)
    attribute(:default_ref, :string, constraints: [trim?: false, max_length: 255])
    attribute(:observed_at, :utc_datetime_usec)
    attribute(:source_run_id, :string)
    attribute(:source_run_generation, :integer)
    attribute(:last_error, :string)
  end

  @doc "Bounded exact branch identity; no normalization, invented default or control characters."
  def valid_ref?(ref) when is_binary(ref) do
    String.valid?(ref) and byte_size(ref) in 1..255 and ref != "@" and
      not Regex.match?(~r/[\x00-\x20\x7f~^:?*\[\\]/u, ref) and
      not String.contains?(ref, ["..", "@{", "//"]) and
      not String.starts_with?(ref, "/") and not String.ends_with?(ref, ["/", "."]) and
      Enum.all?(String.split(ref, "/"), fn part ->
        not String.starts_with?(part, ".") and not String.ends_with?(part, ".lock")
      end)
  end

  def valid_ref?(_), do: false
end
