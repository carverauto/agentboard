defmodule Agentboard.FrontendAuth.Keys do
  @moduledoc false
  @max_bytes 65_536

  def fetch(file, kid) do
    with {:ok, body} when is_binary(body) and byte_size(body) <= @max_bytes <-
           File.open(file, [:read, :binary], &IO.binread(&1, @max_bytes + 1)),
         {:ok, %{"keys" => keys}} when is_list(keys) <- Jason.decode(body),
         true <- length(keys) in 1..32,
         true <- Enum.all?(keys, &public_rsa?/1),
         kids = Enum.map(keys, & &1["kid"]),
         true <- length(Enum.uniq(kids)) == length(kids) do
      case Enum.find(keys, &(&1["kid"] == kid)) do
        nil -> {:error, :unknown_key}
        key -> {:ok, JOSE.JWK.from_map(key)}
      end
    else
      _ -> {:error, :keys_unavailable}
    end
  rescue
    _ -> {:error, :keys_unavailable}
  end

  defp public_rsa?(%{"kty" => "RSA", "kid" => kid, "n" => n, "e" => e} = key) do
    is_binary(kid) and byte_size(kid) in 1..256 and key["alg"] in [nil, "RS256"] and
      key["use"] in [nil, "sig"] and key["key_ops"] in [nil, ["verify"]] and
      Enum.all?(~w(d p q dp dq qi oth), &(not Map.has_key?(key, &1))) and
      valid_modulus?(n) and valid_exponent?(e)
  end

  defp public_rsa?(_), do: false

  defp valid_modulus?(n) when is_binary(n) do
    case Base.url_decode64(n, padding: false) do
      {:ok, <<first, _::binary>> = bytes} -> byte_size(bytes) in 256..1024 and first >= 128
      _ -> false
    end
  end

  defp valid_modulus?(_), do: false

  defp valid_exponent?(e) when is_binary(e) do
    case Base.url_decode64(e, padding: false) do
      {:ok, bytes} when byte_size(bytes) in 1..4 ->
        n = :binary.decode_unsigned(bytes)
        n >= 3 and rem(n, 2) == 1

      _ ->
        false
    end
  end

  defp valid_exponent?(_), do: false
end
