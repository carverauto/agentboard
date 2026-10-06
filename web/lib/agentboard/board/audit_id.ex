defmodule Agentboard.Board.AuditID do
  @moduledoc "Canonical text audit keys for both existing slug and bigint resource identities."
  use Ash.Type.NewType, subtype_of: :string

  def cast_input(value, constraints) when is_integer(value) and value > 0,
    do: super(Integer.to_string(value), constraints)

  def cast_input(value, constraints), do: super(value, constraints)
end

