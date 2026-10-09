defmodule Agentboard.Delivery.BranchFlow.Route do
  @moduledoc "Pure, bounded route validation and filter-bound pagination for the read-only PR view."
  @keys ~w(repo node_kind node view q show_terminal cursor attention_cursor chooser_q chooser_cursor)
  @table_keys ~w(repo node_kind node q show_terminal)
  @page_sizes %{"table" => 20, "chooser" => 20, "attention" => 10}

  def normalize(params) when is_map(params) do
    params = Map.take(params, @keys)

    with {:ok, repo} <- repository(params["repo"]),
         {:ok, q} <- search(params["q"]),
         true <- params["view"] in [nil, "", "overview", "repo"],
         true <- params["show_terminal"] in [nil, "", "true", "false"],
         :ok <- node(repo, params["node_kind"], params["node"]) do
      {:ok,
       params
       |> Map.put("repo", repo)
       |> Map.put("q", q)
       |> Map.put(
         "show_terminal",
         if(params["show_terminal"] == "true", do: "true", else: "false")
       )
       |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
       |> Map.new()}
    else
      {:error, message} -> {:error, message}
      _ -> {:error, "Invalid branch-flow filter. Clear the rejected filter to continue."}
    end
  end

  def normalize(_), do: {:error, "Invalid branch-flow filters."}

  def repository(value) when value in [nil, ""], do: {:ok, nil}

  def repository(value) do
    case Agentboard.SeatScope.canonical_repo(value) do
      nil -> {:error, "Invalid repository. Use its exact owner/repository name."}
      repo -> {:ok, repo}
    end
  end

  def search(value) when value in [nil, ""], do: {:ok, ""}

  def search(value) when is_binary(value) do
    if String.valid?(value) and String.length(value) <= 120 and
         not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
       do: {:ok, value},
       else: {:error, "Search must be at most 120 characters without control characters."}
  end

  def search(_), do: {:error, "Invalid search text."}

  defp node(_repo, kind, value) when kind in [nil, ""] and value in [nil, ""], do: :ok
  defp node(nil, _, _), do: {:error, "Choose a repository before selecting a branch or PR."}

  defp node(_repo, "pr", value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, "Invalid canonical PR identity."}
  end

  defp node(_repo, "base", value) when is_binary(value) do
    if byte_size(value) in 1..255 and String.valid?(value) and
         not Regex.match?(~r/[\x00-\x20\x7F]/u, value),
       do: :ok,
       else: {:error, "Invalid exact base reference (maximum 255 bytes)."}
  end

  defp node(_, _, _), do: {:error, "Invalid branch or PR selection."}

  @doc "Build a URL without broadening rejected filters; nil updates explicitly clear fields."
  def path(params, updates \\ %{}) do
    params = params |> Map.take(@keys) |> Map.merge(Map.take(updates, @keys))

    params =
      case repository(params["repo"]) do
        {:ok, repo} -> Map.put(params, "repo", repo)
        _ -> params
      end

    query =
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} ->
        {key, if(is_binary(value), do: value, else: "\x00invalid")}
      end)
      |> Enum.sort()
      |> URI.encode_query()

    if query == "", do: "/prs", else: "/prs?" <> query
  end

  @doc "Offsets are opaque and bound to the section's complete filter, never accepted across filters."
  def cursor(section, offset, filters) when is_integer(offset) and offset >= 0 do
    Jason.encode!([1, section, offset, fingerprint(section, filters)])
    |> Base.url_encode64(padding: false)
  end

  def offset(nil, _section, _filters), do: {:ok, 0}
  def offset("", _section, _filters), do: {:ok, 0}

  def offset(token, section, filters) when is_binary(token) and byte_size(token) <= 200 do
    expected = fingerprint(section, filters)

    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, [1, ^section, offset, ^expected]} <- Jason.decode(json),
         true <- is_integer(offset) and offset in 0..2_000_000_000,
         size when is_integer(size) <- @page_sizes[section],
         true <- rem(offset, size) == 0 do
      {:ok, offset}
    else
      _ -> {:error, "Invalid or changed-filter cursor. Reset this page to continue."}
    end
  end

  def offset(_, _, _),
    do: {:error, "Invalid cursor (maximum 200 bytes). Reset this page to continue."}

  defp fingerprint("table", filters), do: fingerprint_value(Map.take(filters, @table_keys))
  defp fingerprint("chooser", filters), do: fingerprint_value(Map.take(filters, ["chooser_q"]))
  defp fingerprint("attention", _), do: fingerprint_value(%{"scope" => "all-retained-red"})
  defp fingerprint(_, _), do: "invalid"

  defp fingerprint_value(filters) do
    filters
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> [key, value] end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
