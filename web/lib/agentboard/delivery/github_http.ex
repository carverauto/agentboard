defmodule Agentboard.Delivery.GithubHTTP do
  @moduledoc "Read-only operator-pinned HTTPS transport. No redirects, raw-body errors or implicit retry."
  alias Agentboard.Delivery.ProviderAdmission

  @body_limit 1_048_576

  def get(path, timeout, options \\ []) do
    config = Application.get_env(:agentboard, :github, [])

    with {:ok, base, token} <- destination(config),
         {:ok, %{allowed: true} = admission} <- admit(options[:credit]) do
      headers = [
        {"accept", "application/vnd.github+json"},
        {"accept-encoding", "identity"},
        {"authorization", "Bearer " <> token},
        {"user-agent", "agentboard-ci-observer"},
        {"x-github-api-version", "2022-11-28"}
      ]

      headers = headers ++ Keyword.get(options, :conditional, [])
      deadline = System.monotonic_time(:millisecond) + min(timeout, 10_000)
      ssl = [verify: :verify_peer, timeout: min(timeout, 5_000)]

      ssl =
        if config[:ca_file],
          do: Keyword.put(ssl, :cacertfile, config[:ca_file]),
          else: Keyword.put(ssl, :cacertfile, CAStore.file_path())

      # Connection belongs to this job process; no singleton request/query broker.
      case Mint.HTTP.connect(:https, base.host, base.port,
             mode: :passive,
             protocols: [:http1],
             transport_opts: ssl,
             max_header_list_size: 16_384
           ) do
        {:ok, conn} ->
          try do
            case Mint.HTTP.request(conn, "GET", path, headers, nil) do
              {:ok, conn, ref} ->
                receive_response(conn, ref, deadline, %{
                  status: nil,
                  headers: %{},
                  chunks: [],
                  bytes: 0,
                  done: false
                })
                |> then(fn
                  {:not_modified, headers} ->
                    {:not_modified, headers, Map.get(admission, :window_end)}

                  response ->
                    response
                end)

              {:error, _, _} ->
                {:error, "unavailable", 60}
            end
          after
            Mint.HTTP.close(conn)
          end

        {:error, _} ->
          {:error, "unavailable", 60}
      end
    else
      {:ok, %{allowed: false, retry_after: seconds}} -> {:error, "rate_limited", seconds}
      {:error, "disabled", _} -> {:error, "disabled", 60}
      {:error, _code, _} -> {:error, "unavailable", 60}
      {:error, reason} -> {:error, reason, 60}
    end
  end

  defp admit(nil), do: ProviderAdmission.acquire("github")
  defp admit(credit), do: ProviderAdmission.spend(credit)

  defp receive_response(conn, ref, deadline, result) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "unavailable", 60}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, replies} ->
          result = Enum.reduce(replies, result, &part(&1, &2, ref))

          cond do
            result.bytes > @body_limit ->
              {:error, "incomplete", 60}

            result.done ->
              response(
                result.status,
                result.headers,
                result.chunks |> Enum.reverse() |> IO.iodata_to_binary()
              )

            true ->
              receive_response(conn, ref, deadline, result)
          end

        {:error, _, _, _} ->
          {:error, "unavailable", 60}
      end
    end
  end

  defp part({:status, ref, code}, result, ref), do: %{result | status: code}

  defp part({:headers, ref, headers}, result, ref) do
    headers = Map.new(headers)

    bytes =
      if integer(headers["content-length"]) > @body_limit, do: @body_limit + 1, else: result.bytes

    # Content-Length is an early rejection, not a substitute for streamed size.
    %{result | headers: Map.merge(result.headers, headers), bytes: bytes}
  end

  defp part({:data, ref, chunk}, result, ref) do
    bytes = result.bytes + byte_size(chunk)

    if bytes > @body_limit,
      do: %{result | bytes: bytes},
      else: %{result | chunks: [chunk | result.chunks], bytes: bytes}
  end

  defp part({:done, ref}, result, ref), do: %{result | done: true}
  defp part(_, result, _), do: result

  defp destination(config) do
    base = URI.parse(config[:api_url] || "https://api.github.com")
    token = config[:token]

    if base.scheme == "https" and is_binary(base.host) and base.host != "" and
         is_nil(base.userinfo) and is_nil(base.query) and is_nil(base.fragment) and
         base.path in [nil, "", "/"] and is_binary(token) and token != "" and
         not String.contains?(token, ["\r", "\n"]) do
      {:ok, %{base | path: nil}, token}
    else
      {:error, "unauthorized"}
    end
  end

  defp response(status, headers, body) do
    limited? =
      status == 429 or
        (status == 403 and
           (headers["retry-after"] || headers["x-ratelimit-remaining"] == "0" || secondary?(body)))

    exhausted? = headers["x-ratelimit-remaining"] == "0"

    cooldown =
      if limited? or exhausted?,
        do: ProviderAdmission.block("github", retry_seconds(headers)),
        else: {:ok, :ok}

    with {:ok, _} <- cooldown do
      cond do
        limited? ->
          {:error, "rate_limited", min(retry_seconds(headers), 604_800)}

        status == 304 ->
          {:not_modified, headers}

        status in [401, 403] ->
          {:error, "unauthorized", 300}

        status == 200 ->
          case Jason.decode(body) do
            {:ok, data} -> {:ok, data, headers}
            {:error, _} -> {:error, "incomplete", 60}
          end

        status == 404 ->
          {:error, "unauthorized", 300}

        status in 300..399 ->
          {:error, "incomplete", 60}

        true ->
          {:error, "unavailable", 60}
      end
    else
      {:error, _, _} -> {:error, "unavailable", 60}
    end
  end

  defp secondary?(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) ->
        String.contains?(String.downcase(message), ["rate limit", "abuse detection"])

      _ ->
        false
    end
  end

  defp retry_seconds(headers) do
    # Reset is Unix time, not a duration. Both headers are lower bounds.
    max(
      60,
      max(
        integer(headers["retry-after"]),
        integer(headers["x-ratelimit-reset"]) - System.system_time(:second)
      )
    )
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= 2_147_483_647 -> n
      _ -> 0
    end
  end

  defp integer(_), do: 0
end
