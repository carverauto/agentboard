defmodule Agentboard.Mattermost.InboundHTTP do
  @moduledoc "Server-only bounded authorized REST/WS transport; no redirects or credential-bearing errors."
  alias Mint.HTTP
  @max_bytes 2_097_152

  def segment?(id), do: is_binary(id) and Regex.match?(~r/^[a-zA-Z0-9_-]{1,128}$/, id)

  def destination(cfg) do
    uri = URI.parse(cfg.base_url)
    cond do
      uri.userinfo || uri.query || uri.fragment -> {:error, :forbidden_destination}
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" -> {:ok, uri, :https}
      uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] -> {:ok, uri, :http}
      true -> {:error, :forbidden_destination}
    end
  end

  def connect(cfg, mode) do
    with {:ok, uri, scheme} <- destination(cfg) do
      transport = case Application.get_env(:agentboard, :mattermost_ca_file) do
        file when is_binary(file) and file != "" -> [verify: :verify_peer, cacertfile: String.to_charlist(file)]
        _ -> [verify: :verify_peer]
      end
      case HTTP.connect(scheme, uri.host, uri.port, protocols: [:http1], mode: mode,
             transport_opts: if(scheme == :https, do: transport, else: []), timeout: timeout()) do
        {:ok, conn} -> {:ok, conn, uri, scheme}
        _ -> {:error, :transport_error}
      end
    end
  end

  def path(uri, suffix), do: String.trim_trailing(uri.path || "", "/") <> suffix
  def timeout, do: Application.get_env(:agentboard, :mattermost_request_timeout_ms, 10_000)
  def me(cfg), do: get(cfg, "/api/v4/users/me")
  def channels(cfg), do: get(cfg, "/api/v4/users/me/channels")
  def post(cfg, id) do
    if segment?(id), do: get(cfg, "/api/v4/posts/#{id}"), else: {:error, :invalid_id}
  end
  def page(cfg, channel, page) do
    if segment?(channel), do: get(cfg, "/api/v4/channels/#{channel}/posts?page=#{page}&per_page=60"), else: {:error, :invalid_id}
  end

  def get(cfg, suffix) do
    with {:ok, conn, uri, _} <- connect(cfg, :passive) do
      try do
        case HTTP.request(conn, "GET", path(uri, suffix), [{"authorization", "Bearer " <> cfg.token}], nil) do
          {:ok, conn, ref} -> receive_body(conn, ref, System.monotonic_time(:millisecond) + timeout(), nil, [], "")
          _ -> {:error, :transport_error}
        end
      after
        HTTP.close(conn)
      end
    end
  end

  defp receive_body(conn, ref, deadline, status, headers, body) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0 do
      {:error, :timeout}
    else
      case HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          {status, headers, body, done} = Enum.reduce(responses, {status, headers, body, false}, fn
            {:status, ^ref, s}, {_, h, b, d} -> {s, h, b, d}
            {:headers, ^ref, h}, {s, _, b, d} -> {s, h, b, d}
            {:data, ^ref, b}, {s, h, acc, d} -> {s, h, acc <> b, d}
            {:done, ^ref}, {s, h, b, _} -> {s, h, b, true}
            _, acc -> acc
          end)
          cond do
            byte_size(body) > @max_bytes -> {:error, :response_too_large}
            done -> decode(status, headers, body)
            true -> receive_body(conn, ref, deadline, status, headers, body)
          end
        _ -> {:error, :transport_error}
      end
    end
  end

  defp decode(200, _, body), do: Jason.decode(body)
  defp decode(status, _, _) when status in [401, 403, 404], do: {:error, :source_unavailable}
  defp decode(429, headers, _), do: {:error, {:rate_limited, Agentboard.Mattermost.Transport.retry_after(headers) || 60}}
  defp decode(_, _, _), do: {:error, :unexpected_status}
end
