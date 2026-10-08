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

  # Paging bounds for channel-history scans. Declared before use: Elixir
  # reads module attributes at compile time, so a later declaration
  # would silently nil the guards below and unbind the scan.
  @history_per_page 60
  @history_max_pages 5

  defp request_timeout,
    do: Application.get_env(:agentboard, :mattermost_request_timeout_ms, 10_000)

  def post(cfg, channel_id, message, marker, root_id \\ nil) do
    body =
      %{channel_id: channel_id, message: message, props: %{agentboard_event_marker: marker}}
      |> maybe_root(root_id)
      |> Jason.encode!()

    request(cfg, :post, "/api/v4/posts", body)
  end

  # Agent post through whichever bot credential the caller supplies. Props are the source of truth for
  # attribution; override fields render only when the server enables the
  # Mattermost override settings, and the header line plus props carry
  # identity either way.
  def post_agent(cfg, channel_id, message, props, opts \\ []) do
    body =
      %{channel_id: channel_id, message: message, props: props}
      |> maybe_root(Keyword.get(opts, :root_id))
      |> maybe_override("override_username", Keyword.get(opts, :override_username))
      |> maybe_override("override_icon_url", Keyword.get(opts, :override_icon_url))
      |> Jason.encode!()

    request(cfg, :post, "/api/v4/posts", body)
  end

  defp maybe_override(map, _key, nil), do: map
  defp maybe_override(map, _key, ""), do: map
  defp maybe_override(map, key, value), do: Map.put(map, key, value)

  # Retry-key adoption scoped to the posting agent: a matching key from a
  # different agent_id is a different message, never a duplicate.
  def find_by_retry_key(cfg, channel_id, retry_key, agent_id) do
    search_retry_key(cfg, channel_id, retry_key, agent_id, 0)
  end

  defp search_retry_key(_cfg, _channel_id, _retry_key, _agent_id, page) when page >= @history_max_pages,
    do: {:ok, nil}

  defp search_retry_key(cfg, channel_id, retry_key, agent_id, page) do
    case request(cfg, :get, "/api/v4/channels/#{channel_id}/posts?page=#{page}&per_page=#{@history_per_page}", nil) do
      {:ok, 200, posts} ->
        case find_in_retry(posts, retry_key, agent_id) do
          nil ->
            if has_more?(posts),
              do: search_retry_key(cfg, channel_id, retry_key, agent_id, page + 1),
              else: {:ok, nil}

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

  defp find_in_retry(posts, retry_key, agent_id) do
    (posts["posts"] || %{})
    |> Map.values()
    |> Enum.find(fn post ->
      get_in(post, ["props", "agentboard_retry_key"]) == retry_key and
        get_in(post, ["props", "agent_id"]) == agent_id
    end)
  end

  def channel_page(cfg, channel_id, page, per_page) do
    request(cfg, :get, "/api/v4/channels/#{channel_id}/posts?page=#{page}&per_page=#{per_page}", nil)
  end

  # Reconciliation: find a post we may have created before losing the
  # response. Channel history is authoritative; a client-sent idempotency
  # key alone never proves the remote accepted anything.
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

  # Phase 2 elastic bot admin calls. These run with the server-held
  # provisioner credential, never an agent credential. Bodies are small
  # maps; responses are matched by shape, never logged.
  def create_bot(cfg, username, display_name) do
    body = Jason.encode!(%{username: username, display_name: display_name})

    case request(cfg, :post, "/api/v4/bots", body) do
      {:ok, 201, %{"user_id" => _} = bot} -> {:ok, bot}
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_bot_token(cfg, bot_user_id) do
    body = Jason.encode!(%{description: "agentboard elastic agent bot"})

    case request(cfg, :post, "/api/v4/bots/#{bot_user_id}/token", body) do
      {:ok, 200, %{"token" => token}} when is_binary(token) -> {:ok, token}
      {:ok, 200, %{"token" => %{"token" => token}}} when is_binary(token) -> {:ok, token}
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_bot_active(cfg, bot_user_id, true) do
    case request(cfg, :post, "/api/v4/bots/#{bot_user_id}/enable", Jason.encode!(%{})) do
      {:ok, 200, _} -> :ok
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_bot_active(cfg, bot_user_id, false) do
    case request(cfg, :post, "/api/v4/bots/#{bot_user_id}/disable", Jason.encode!(%{})) do
      {:ok, 200, _} -> :ok
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_user_tokens(cfg, user_id) do
    case request(cfg, :get, "/api/v4/users/#{user_id}/tokens", nil) do
      {:ok, 200, tokens} when is_list(tokens) -> {:ok, tokens}
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke_user_token(cfg, user_id, token_id) do
    body = Jason.encode!(%{token_id: token_id})

    case request(cfg, :post, "/api/v4/users/#{user_id}/tokens/revoke", body) do
      {:ok, 200, _} -> :ok
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  def add_team_member(cfg, team_id, user_id) do
    body = Jason.encode!(%{team_id: team_id, user_id: user_id})

    case request(cfg, :post, "/api/v4/teams/#{team_id}/members", body) do
      {:ok, 201, _} -> :ok
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
    end
  end

  def add_channel_member(cfg, channel_id, user_id) do
    body = Jason.encode!(%{user_id: user_id})

    case request(cfg, :post, "/api/v4/channels/#{channel_id}/members", body) do
      {:ok, 201, _} -> :ok
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, _status, _} -> {:error, :unconfirmed}
      {:error, reason} -> {:error, reason}
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
    # Lists pass through untouched (e.g. token listings); maps carry the
    # header along for callers that match on it.
    case parsed do
      {:ok, json} when is_map(json) ->
        Map.put(json, "_retry_after", retry_after(headers))

      {:ok, json} when is_list(json) ->
        json

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
