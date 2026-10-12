defmodule Agentboard.MessageHistory do
  @moduledoc """
  Historical board-message compatibility across message modes (OpenSpec 7.2).

  Board history stays readable, exportable and individually acknowledgeable
  by recipients in every mode. Only an *effective* `mattermost` mode retires
  legacy sends; a refused cutover leaves the working board inbox unchanged.
  Selecting `board` again re-enables sends without touching history.
  """
  alias Agentboard.Board
  alias Agentboard.Mattermost.{Bridge, TaskThread}
  require Ash.Query

  @export_filters ~w(to task cursor limit)
  @export_page_size "100"
  @chat_command "agentboard chat send"

  @doc "Effective transport; `mattermost` only after the readiness gate accepts it."
  def mode, do: Agentboard.MessageMode.status().effective

  def migrated?(mode \\ mode()), do: mode == "mattermost"

  @doc "Additive `GET /api/v1/meta` capability advertisement."
  def status do
    mode = mode()

    %{
      export_supported: true,
      legacy_sends: if(migrated?(mode), do: "migrated", else: "open"),
      archive_path: "/messages",
      export_path: "/api/v1/messages/export",
      chat_command: @chat_command
    }
  end

  @doc """
  Legacy `msg send` gate. Refused only in effective `mattermost` mode, with a
  machine-readable migration pointer; recipient acknowledgement is not gated.
  """
  def authorize_legacy_send do
    if migrated?() do
      {:error, "message_transport_migrated",
       "Board message sends are retired in mattermost mode; use `#{@chat_command}`. " <>
         "Board history stays readable and exportable, and pending direct messages " <>
         "remain acknowledgeable with `agentboard msg read ID`.",
       %{
         migration: %{
           mode: "mattermost",
           command: @chat_command,
           archive_path: "/messages",
           export_path: "/api/v1/messages/export",
           acknowledge_command: "agentboard msg read ID"
         }
       }}
    else
      :ok
    end
  end

  @doc """
  One bounded, ordered (`created_at`, `id`) export page using the existing
  filter-bound message cursor. Reading never acknowledges.
  """
  def export_page(params) when is_map(params) do
    case Map.keys(params) -- @export_filters do
      [] -> Board.page("messages", Map.put_new(params, "limit", @export_page_size))
      _ -> {:error, "invalid_input", "Message export accepts only to, task, cursor and limit"}
    end
  end

  @doc """
  Export encoding. JSON escapes every control character, so one record never
  spans lines; U+2028/U+2029 are escaped too for line-splitting consumers.
  """
  def encode(value), do: Jason.encode_to_iodata!(value, escape: :javascript_safe)

  @doc "Dashboard navigation for the current mode. Mattermost links only when cut over."
  def navigation(task_id \\ nil) do
    mode = mode()
    url = if migrated?(mode), do: mattermost_url()

    %{
      mode: mode,
      migrated: migrated?(mode),
      mattermost_url: url,
      thread_url: if(url && task_id, do: thread_url(url, task_id))
    }
  end

  @doc "NDJSON export link for the dashboard, preserving recipient/task filters."
  def download_path(filters) do
    case filters |> Map.take(~w(to task)) |> Map.reject(fn {_, v} -> v in [nil, ""] end) do
      empty when empty == %{} -> "/messages/export"
      query -> "/messages/export?" <> URI.encode_query(query)
    end
  end

  # Only an absolute http(s) base URL may become a browser link.
  defp mattermost_url do
    with base when is_binary(base) <- Bridge.base_url(),
         %URI{scheme: scheme, host: host} when scheme in ~w(http https) and host not in [nil, ""] <-
           URI.parse(String.trim(base)) do
      String.trim_trailing(String.trim(base), "/")
    else
      _ -> nil
    end
  end

  # A rooted task-thread mapping opens the exact root post through the
  # team-independent permalink route; otherwise the caller links the server.
  defp thread_url(base, task_id) do
    query = TaskThread |> Ash.Query.filter(task_id == ^task_id)

    case Ash.read_one(Agentboard.Repo.read_query(query)) do
      {:ok, %{root_post_id: post}} when is_binary(post) and post != "" ->
        base <> "/_redirect/pl/" <> URI.encode(post, &URI.char_unreserved?/1)

      _ ->
        nil
    end
  rescue
    DBConnection.ConnectionError -> nil
    Postgrex.Error -> nil
  end
end
