defmodule Agentboard.FrontendAuth do
  @moduledoc """
  Optional human authentication, independent of agent and captain capabilities.

  Only a signed Cloudflare Access application assertion is accepted on HTTP.
  The public JWKS is an operator-installed file; token headers and claims can
  never choose a key URL. Every HTTP verification reads that bounded file, so
  a failed or removed key file never falls back to stale keys.
  """
  alias Agentboard.FrontendAuth.Keys

  @issuer ~r/\Ahttps:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com\z/
  @clock_skew 30
  @max_token_bytes 16_384

  def enabled? do
    case config() do
      {:ok, %{mode: :off}} -> false
      _ -> true
    end
  end

  def config, do: validate_config(configured())

  def validate_config(options) when is_list(options) do
    mode = Keyword.get(options, :mode, "off")

    if mode == "off" do
      {:ok, %{mode: :off}}
    else
      issuer = options[:issuer]
      audience = options[:audience]
      file = options[:jwks_file]
      emails = Keyword.get(options, :allowed_emails, [])
      subjects = Keyword.get(options, :allowed_subjects, [])
      ttl = Keyword.get(options, :session_ttl_seconds, 300)

      if mode == "cloudflare_access" and text?(issuer, 255) and
           Regex.match?(@issuer, issuer) and text?(audience, 512) and
           text?(file, 4096) and Path.type(file) == :absolute and
           allowlist?(emails, 320) and allowlist?(subjects, 256) and
           (emails != [] or subjects != []) and is_integer(ttl) and ttl in 1..300 do
        {:ok,
         %{
           mode: :cloudflare_access,
           issuer: issuer,
           audience: audience,
           jwks_file: file,
           allowed_emails: Enum.map(emails, &String.downcase/1),
           allowed_subjects: subjects,
           session_ttl_seconds: ttl
         }}
      else
        {:error, :misconfigured}
      end
    end
  end

  def validate_config(_), do: {:error, :misconfigured}

  def verify(token, config, now \\ System.system_time(:second))

  def verify(token, %{mode: :cloudflare_access} = config, now)
      when is_binary(token) and byte_size(token) <= @max_token_bytes do
    with {:ok, header} <- token |> JOSE.JWS.peek_protected() |> Jason.decode(),
         true <- safe_header?(header),
         {:ok, key} <- Keys.fetch(config.jwks_file, header["kid"]),
         {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(key, ["RS256"], token),
         {:ok, principal} <- validate_claims(claims, config, now) do
      {:ok, principal}
    else
      {:error, :keys_unavailable} -> {:error, :unavailable}
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  def verify(_, _, _), do: {:error, :unauthorized}

  def policy_id(config), do: :crypto.hash(:sha256, :erlang.term_to_binary(config))

  def allowed?(%{subject: subject, email: email}, config) do
    subject in config.allowed_subjects or String.downcase(email) in config.allowed_emails
  end

  defp configured do
    Application.get_env(:agentboard, :frontend_auth, mode: "off")
  end

  defp validate_claims(claims, config, now) do
    exp = claims["exp"]
    iat = claims["iat"]
    nbf = claims["nbf"]
    email = claims["email"]
    subject = claims["sub"]
    audiences = claims["aud"]

    if claims["iss"] == config.issuer and claims["type"] == "app" and
         audience?(audiences, config.audience) and is_integer(exp) and exp > now and
         exp <= 253_402_300_799 and is_integer(iat) and iat >= 0 and
         iat <= now + @clock_skew and iat < exp and valid_nbf?(nbf, now, exp) and
         text?(subject, 256) and text?(email, 320) and String.contains?(email, "@") and
         not Map.has_key?(claims, "common_name") and
         not Map.has_key?(claims, "service_token_id") and
         claims["service_token_status"] in [nil, false] do
      principal = %{subject: subject, email: email, jwt_expires_at: exp}
      if allowed?(principal, config), do: {:ok, principal}, else: {:error, :forbidden}
    else
      {:error, :unauthorized}
    end
  end

  defp safe_header?(%{"alg" => "RS256", "kid" => kid} = header) do
    text?(kid, 256) and header["typ"] in [nil, "JWT"] and
      Enum.all?(~w(jku jwk x5u x5c crit b64), &(not Map.has_key?(header, &1)))
  end

  defp safe_header?(_), do: false
  defp audience?(aud, expected) when is_binary(aud), do: aud == expected

  defp audience?(aud, expected) when is_list(aud),
    do: length(aud) in 1..32 and Enum.all?(aud, &is_binary/1) and expected in aud

  defp audience?(_, _), do: false
  defp valid_nbf?(nil, _, _), do: true

  defp valid_nbf?(nbf, now, exp),
    do: is_integer(nbf) and nbf >= 0 and nbf <= now + @clock_skew and nbf < exp

  defp allowlist?(list, size) when is_list(list),
    do: length(list) <= 1000 and Enum.all?(list, &text?(&1, size))

  defp allowlist?(_, _), do: false

  defp text?(text, size) when is_binary(text),
    do:
      byte_size(text) in 1..size and String.valid?(text) and text == String.trim(text) and
        not String.contains?(text, ["\r", "\n", "\0"])

  defp text?(_, _), do: false
end
