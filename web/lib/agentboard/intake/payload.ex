defmodule Agentboard.Intake.Payload do
  @moduledoc """
  Strict validation and normalization of an intake request.

  Normalization is the replay identity: repository lowercased `owner/repo`,
  title and body trimmed, integer priority (lower is more urgent), labels
  trimmed, sorted and deduplicated, and a boolean issue flag (default true).
  Two requests with the same key and the same normalized items replay; any
  normalized difference conflicts. An import request normalizes its issue
  selection the same way and digests it under its own tag.
  """
  alias Agentboard.SeatScope

  @max_items 10
  @max_key 128
  # GitHub caps titles at 256 characters and bodies at 65,536; the body
  # bound leaves room for the hidden intake marker.
  @max_title 256
  @max_body 60_000
  @max_labels 20
  @max_label 50
  @item_fields ~w(repository title body priority labels issue)
  @fields ~w(request_key items)

  @shape_error "Intake requires request_key (1-128 bytes) and 1-10 items, each with repository (owner/repo) and title, optional body, priority (integer >= 0), labels (up to 20) and issue (boolean); unknown fields are forbidden"

  def normalize(data) when is_map(data) do
    with true <- Enum.all?(Map.keys(data), &(&1 in @fields)),
         {:ok, key} <- request_key(data["request_key"]),
         items when is_list(items) and length(items) in 1..@max_items <- data["items"],
         {:ok, items} <- items(items) do
      {:ok, %{"request_key" => key, "items" => items}}
    else
      _ -> {:error, "invalid_input", @shape_error}
    end
  end

  def normalize(_), do: {:error, "invalid_input", @shape_error}

  @import_fields ~w(request_key repository issues labels limit priority start_page)
  @import_error "Import requires request_key (1-128 bytes) and repository (owner/repo), then either issues (1-10 distinct issue numbers) or an optional labels filter (up to 20) with limit (1-10, default 10) and start_page (integer >= 1, default 1), plus optional priority (integer >= 0, default 3); unknown fields are forbidden"

  # An import selects existing issues instead of describing new ones. Named
  # issue numbers keep the caller's order; a list selection is the first
  # `limit` open issues in GitHub's order that are not yet on the board.
  def normalize_import(data) when is_map(data) do
    with true <- Enum.all?(Map.keys(data), &(&1 in @import_fields)),
         {:ok, key} <- request_key(data["request_key"]),
         repository when is_binary(repository) <- SeatScope.canonical_repo(data["repository"]),
         {:ok, selection} <- selection(data),
         priority when is_integer(priority) and priority in 0..2_147_483_647 <-
           Map.get(data, "priority", 3) do
      {:ok,
       %{
         "request_key" => key,
         "repository" => repository,
         "selection" => selection,
         "priority" => priority
       }}
    else
      _ -> {:error, "invalid_input", @import_error}
    end
  end

  def normalize_import(_), do: {:error, "invalid_input", @import_error}

  # Tagged so a filing and an import can never replay each other; field
  # order is fixed like `digest/1`.
  def import_digest(%{"selection" => selection} = request) do
    canonical = [
      "import",
      request["repository"],
      selection["issues"],
      selection["labels"],
      selection["limit"],
      selection["start_page"],
      request["priority"]
    ]

    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  # GitHub labels become card labels under the same bounds as filed labels;
  # names the board cannot hold are left off rather than failing the import.
  def issue_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [String.trim(name)]
      _ -> []
    end)
    |> Enum.filter(&label?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_labels)
  end

  def issue_labels(_), do: []

  # A card title from an issue title: single line, bounded like a filed title.
  def issue_title(title, number) do
    title =
      if is_binary(title) and String.valid?(title),
        do: title |> String.replace(~r/[\p{Cc}\p{Cf}]+/u, " ") |> String.trim(),
        else: ""

    if title == "",
      do: "Issue ##{number}",
      else: title |> String.slice(0, @max_title) |> String.trim_trailing()
  end

  # The card description: the issue link, then the issue body within the
  # filed-body bound.
  def issue_description(url, body) do
    body = if is_binary(body) and String.valid?(body), do: String.trim(body), else: ""
    String.trim("Imported from #{url}\n\n" <> String.slice(body, 0, @max_body))
  end

  defp selection(%{"issues" => numbers} = data)
       when is_list(numbers) and length(numbers) in 1..@max_items do
    valid? =
      not Map.has_key?(data, "labels") and not Map.has_key?(data, "limit") and
        not Map.has_key?(data, "start_page") and
        Enum.all?(numbers, &(is_integer(&1) and &1 in 1..2_147_483_647)) and
        length(Enum.uniq(numbers)) == length(numbers)

    if valid?, do: {:ok, %{"issues" => numbers}}, else: :error
  end

  defp selection(data) when not is_map_key(data, "issues") do
    with {:ok, labels} <- labels(Map.get(data, "labels", [])),
         limit when is_integer(limit) and limit in 1..@max_items <-
           Map.get(data, "limit", @max_items),
         start when is_integer(start) and start in 1..2_147_483_647 <-
           Map.get(data, "start_page", 1) do
      {:ok, %{"labels" => labels, "limit" => limit, "start_page" => start}}
    else
      _ -> :error
    end
  end

  defp selection(_), do: :error

  # Field order is fixed so the digest never depends on map ordering.
  def digest(items) do
    canonical =
      Enum.map(items, fn item ->
        [
          item["repository"],
          item["title"],
          item["body"],
          item["priority"],
          item["labels"],
          item["issue"]
        ]
      end)

    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  defp request_key(key) when is_binary(key) do
    key = String.trim(key)

    if key != "" and byte_size(key) <= @max_key and printable?(key),
      do: {:ok, key},
      else: :error
  end

  defp request_key(_), do: :error

  defp items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case item(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      :error -> :error
    end
  end

  defp item(item) when is_map(item) do
    with true <- Enum.all?(Map.keys(item), &(&1 in @item_fields)),
         repository when is_binary(repository) <- SeatScope.canonical_repo(item["repository"]),
         {:ok, title} <- text(item["title"], @max_title, false),
         {:ok, body} <- text(Map.get(item, "body", ""), @max_body, true),
         # Only the server writes intake markers; a body must not forge one.
         false <- String.contains?(body, "agentboard-intake:"),
         priority when is_integer(priority) and priority in 0..2_147_483_647 <-
           Map.get(item, "priority", 3),
         {:ok, labels} <- labels(Map.get(item, "labels", [])),
         issue when is_boolean(issue) <- Map.get(item, "issue", true) do
      {:ok,
       %{
         "repository" => repository,
         "title" => title,
         "body" => body,
         "priority" => priority,
         "labels" => labels,
         "issue" => issue
       }}
    else
      _ -> :error
    end
  end

  defp item(_), do: :error

  defp text(value, max, allow_empty?) when is_binary(value) do
    value = String.trim(value)

    cond do
      not String.valid?(value) -> :error
      value == "" and not allow_empty? -> :error
      String.length(value) > max or byte_size(value) > max * 4 -> :error
      not allow_empty? and not printable?(value) -> :error
      true -> {:ok, value}
    end
  end

  defp text(_, _, _), do: :error

  defp labels(labels) when is_list(labels) and length(labels) <= @max_labels do
    if Enum.all?(labels, &label?/1),
      do: {:ok, labels |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.sort()},
      else: :error
  end

  defp labels(_), do: :error

  defp label?(label) when is_binary(label) do
    trimmed = String.trim(label)
    trimmed != "" and String.length(trimmed) <= @max_label and printable?(trimmed)
  end

  defp label?(_), do: false

  # Single-line text: no control or format characters.
  defp printable?(value),
    do: String.valid?(value) and not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value)
end
