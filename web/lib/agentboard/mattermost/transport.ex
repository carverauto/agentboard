defmodule Agentboard.Mattermost.Transport do
  @moduledoc """
  Minimal Mattermost REST client over OTP `:httpc`. No new dependencies.

  Destination restriction: the only remote talked to is the configured base
  URL, `https` with peer verification, except loopback hosts (`127.0.0.1`,
  `::1`, `localhost`) which may use plain HTTP for controlled fixtures.
  Anything else is refused before any byte is sent. All calls carry an
  explicit deadline; bodies are bounded by the caller.
  """

  @user_agent "agentboard-bridge/1"

  defp request_timeout,
    do: Application.get_env(:agentboard, :mattermost_request_timeout_ms, 10_000)

  def post(cfg, channel_id, message, marker, root_id \\ nil) do
    body =
      %{channel_id: channel_id, message: message, props: %{agentboard_event_marker: marker}}
      |> maybe_root(root_id)
      |> Jason.encode!()

    request(cfg, :post, "/api/v4/posts", body)
  end

  # Reconciliation: find a post we may have created before losing the
  # response. Channel history is authoritative; a client-sent idempotency
  # key alone never proves the remote accepted anything.
  @history_per_page 60
  @history_max_pages 5

  def find_by_marker(cfg, channel_id, marker) do
    search_channel(cfg, channel_id, marker, 0)
  end

  def find_reply_by_marker(cfg, channel_id, root_id, marker) do
    case request(cfg, :get, "/api/v4/posts/#{root_id}/thread", nil) do
      {:ok, 200, posts} ->
        case find_in_posts(posts, marker) do
          nil -> search_channel(cfg, channel_id, marker, 0)
          match -> {:ok, match}
        end

      {:ok, status, _} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, _status, _} ->
        search_channel(cfg, channel_id, marker, 0)

      {:error, _} ->
        search_channel(cfg, channel_id, marker, 0)
    end
  end

  defp search_channel(cfg, channel_id, marker, page) when page < @history_max_pages do
    case request(cfg, :get, "/api/v4/channels/#{channel_id}/posts?page=#{page}&per_page=#{@history_per_page}", nil) do
      {:ok, 200, posts} ->
        case find_in_posts(posts, marker) do
          nil ->
            if has_more?(posts), do: search_channel(cfg, channel_id, marker, page + 1), else: {:ok, nil}

          match ->
            {:ok, match}
        end

      {:ok, status, _} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, 404, _} ->
        {:error, :not_found}

      {:ok, _status, _} ->
        {:error, :unconfirmed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_channel(_cfg, _channel_id, _marker, _page), do: {:ok, nil}

  defp find_in_posts(posts, marker) do
    (posts["posts"] || %{})
    |> Map.values()
    |> Enum.find(fn post -> get_in(post, ["props", "agentboard_event_marker"]) == marker end)
  end

  defp has_more?(posts) do
    case posts["order"] do
      order when is_list(order) -> length(order) >= @history_per_page
      _ -> false
    end
  end

  def channel_ok?(cfg, channel_id) do
    case request(cfg, :get, "/api/v4/channels/#{channel_id}", nil) do
      {:ok, 200, _} -> true
      _ -> false
    end
  end

  # Read-only liveness probe used at enablement: proves the full TLS stack
  # (trust chain plus hostname match) before any board event posts.
  def ping(cfg) do
    case request(cfg, :get, "/api/v4/system/ping", nil) do
      {:ok, 200, body} -> {:ok, body}
      {:ok, status, _} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Identity verification: user record plus team membership, both by stable ID.
  # A renamed handle keeps the same user ID; attribution follows the ID.
  def fetch_user(cfg, user_id) do
    case request(cfg, :get, "/api/v4/users/#{user_id}", nil) do
      {:ok, 200, %{"id" => id, "username" => username}} -> {:ok, %{id: id, username: username}}
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, 401, _} -> {:error, :unauthorized}
      {:ok, 403, _} -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unreachable}
      {:error, reason} -> {:error, reason}
    end
  end

  def team_member?(cfg, team_id, user_id) do
    case request(cfg, :get, "/api/v4/teams/#{team_id}/members/#{user_id}", nil) do
      {:ok, 200, _} -> {:ok, true}
      {:ok, 404, _} -> {:ok, false}
      {:ok, 401, _} -> {:error, :unauthorized}
      {:ok, 403, _} -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unreachable}
      {:error, reason} -> {:error, reason}
    end
  end

  # Multi-page reconcile lives in find_by_marker/search_channel above; this
  # module keeps one history-search implementation.

  defp maybe_root(map, nil), do: map
  defp maybe_root(map, root_id), do: Map.put(map, :root_id, root_id)

  defp request(cfg, method, path, body) do
    with {:ok, url, http_opts} <- destination(cfg, path),
         :ok <- ensure_httpc(),
         headers = [
           {~c"authorization", String.to_charlist("Bearer #{cfg.token}")},
           {~c"content-type", ~c"application/json"},
           {~c"user-agent", String.to_charlist(@user_agent)}
         ],
         req = request_tuple(method, url, headers, body),
         {:ok, {{_, status, _}, resp_headers, resp_body}} <-
           :httpc.request(method, req, [{:timeout, request_timeout()} | http_opts], []) do
      {:ok, status, decode(resp_body, status, resp_headers)}
    else
      {:error, {:failed_connect, _}} -> {:error, :unreachable}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_tuple(:get, url, headers, _body), do: {url, headers}

  defp request_tuple(_method, url, headers, body),
    do: {url, headers, ~c"application/json", body}

  defp decode(body, status, headers) do
    parsed =
      body |> IO.iodata_to_binary() |> Jason.decode()

    # Retry-After rides along regardless of body shape; callers match on it.
    case parsed do
      {:ok, json} when is_map(json) ->
        Map.put(json, "_retry_after", retry_after(headers))

      _ ->
        %{"_raw_status" => status, "_retry_after" => retry_after(headers)}
    end
  end

  def retry_after(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} ->
        if String.downcase(to_string(key)) == "retry-after",
          do: parse_retry_after(to_string(value)),
          else: nil
    end)
  end

  defp parse_retry_after(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, _} when seconds in 1..3_600 -> seconds
      _ -> nil
    end
  end

  defp destination(%{base_url: base_url}, path) do
    uri = URI.parse(base_url <> path)

    cond do
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" ->
        {:ok, String.to_charlist(URI.to_string(uri)), [ssl: https_opts()]}

      uri.scheme == "http" and uri.host in ["127.0.0.1", "::1", "localhost"] ->
        {:ok, String.to_charlist(URI.to_string(uri)), []}

      true ->
        {:error, :forbidden_destination}
    end
  end

  # Live farm01 proved the packaged default insufficient two ways: no CA
  # source verifies nothing, and the default hostname check rejects the
  # cluster wildcard. verify_peer stays on; trust falls back from explicit
  # config to the image bundle to OTP built-ins, and hostname matching uses
  # the HTTPS match fun explicitly.
  defp https_opts do
    base = [
      {:verify, :verify_peer},
      {:depth, 4},
      {:customize_hostname_check,
       [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]}
    ]

    case ca_source() do
      {:file, file} -> [{:cacertfile, String.to_charlist(file)} | base]
      {:cacerts, certs} -> [{:cacerts, certs} | base]
      :none -> base
    end
  end

  defp ca_source do
    case Application.get_env(:agentboard, :mattermost_ca_file) do
      file when is_binary(file) and file != "" ->
        {:file, file}

      _ ->
        bundle = "/etc/ssl/certs/ca-certificates.crt"

        cond do
          File.exists?(bundle) -> {:file, bundle}
          function_exported?(:public_key, :cacerts_get, 0) -> {:cacerts, :public_key.cacerts_get()}
          true -> :none
        end
    end
  end

  defp ensure_httpc do
    case Application.ensure_started(:inets) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end
end
