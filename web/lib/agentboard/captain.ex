defmodule Agentboard.Captain do
  @moduledoc "Captain capability for reversible board housekeeping; agent attribution is not authentication."
  def configured?, do: is_binary(token()) and byte_size(token()) >= 32

  def authenticate(value) when is_binary(value) do
    if configured?() and Plug.Crypto.secure_compare(value, token()),
      do: %{"proof" => digest(), "expires" => System.system_time(:second) + 43_200},
      else: nil
  end

  def authenticate(_), do: nil

  # Header parsing is shared; attribution headers never enter this verifier.
  def authenticate_header(conn, header \\ "authorization") do
    case {header, Plug.Conn.get_req_header(conn, header)} do
      {"authorization", ["Bearer " <> value]} -> authenticate(value)
      {"x-agentboard-captain-token", [value]} -> authenticate(value)
      _ -> nil
    end
  end

  def authorized?(%{"proof" => proof, "expires" => expires})
      when is_binary(proof) and is_integer(expires) do
    configured?() and expires > System.system_time(:second) and
      Plug.Crypto.secure_compare(proof, digest())
  end

  def authorized?(_), do: false
  def actor, do: %{role: :captain, id: "captain"}
  defp token, do: Application.get_env(:agentboard, :captain_token)
  defp digest, do: :crypto.hash(:sha256, token()) |> Base.encode16(case: :lower)
end
