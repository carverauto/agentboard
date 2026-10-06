defmodule Agentboard.Input do
  @slug ~r/^[a-z0-9][a-z0-9_-]{0,127}$/
  @issue ~r/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/[1-9][0-9]*$/
  def slug?(value), do: is_binary(value) and Regex.match?(@slug, value)
  def text?(value), do: is_binary(value) and String.trim(value) != ""

  def actor(%{"agent" => id, "model" => model, "harness" => harness} = actor) do
    if slug?(id) and text?(model) and text?(harness) and byte_size(model) <= 256 and
         byte_size(harness) <= 128,
       do: {:ok, actor},
       else: {:error, "invalid_context", "Agent, model, and harness are required"}
  end

  def actor(_), do: {:error, "invalid_context", "Agent, model, and harness are required"}

  def task(action, data) when is_map(data) do
    fields =
      case action do
        "create" -> ~w(id title description priority repo labels issue_url pr_url)
        "edit" -> ~w(title description priority repo labels issue_url pr_url revision)
        "link" -> ~w(issue_url pr_url revision)
        "assign" -> ~w(to revision)
        "handoff" -> ~w(to note revision)
        a when a in ~w(claim renew reclaim) -> ~w(ttl_seconds revision)
        "release" -> ~w(expired revision)
        "update" -> ~w(status note revision)
        _ -> []
      end

    valid = Enum.all?(data, fn {key, value} -> key in fields and valid_field?(key, value) end)

    required =
      case action do
        "create" ->
          text?(data["title"])

        "assign" ->
          slug?(data["to"])

        "handoff" ->
          slug?(data["to"]) and text?(data["note"])

        "edit" ->
          map_size(Map.drop(data, ["revision"])) > 0

        "link" ->
          Map.has_key?(data, "issue_url") or Map.has_key?(data, "pr_url")

        "update" ->
          text?(data["note"]) or data["status"] in ~w(blocked review done cancelled in_progress)

        a when a in ~w(claim renew release reclaim) ->
          true

        _ ->
          false
      end

    if valid and required,
      do: :ok,
      else: {:error, "invalid_input", "Invalid task fields or action"}
  end

  def task(_, _), do: {:error, "invalid_input", "Task payload must be an object"}

  def registration(data) when is_map(data) do
    valid =
      Enum.all?(data, fn
        {"name", value} -> text?(value)
        {"host", value} -> is_nil(value) or is_binary(value)
        {"capabilities", value} -> strings?(value)
        {"metadata", value} -> is_map(value)
        _ -> false
      end)

    if valid, do: :ok, else: {:error, "invalid_input", "Invalid agent registration fields"}
  end

  def registration(_), do: {:error, "invalid_input", "Agent payload must be an object"}

  defp valid_field?("id", value), do: slug?(value)
  defp valid_field?("title", value), do: text?(value)
  defp valid_field?("description", value), do: is_binary(value)

  defp valid_field?("priority", value),
    do: is_integer(value) and value >= 0 and value <= 2_147_483_647

  defp valid_field?("repo", value), do: is_nil(value) or is_binary(value)
  defp valid_field?("labels", value), do: strings?(value)

  defp valid_field?("issue_url", value),
    do: is_nil(value) or (is_binary(value) and Regex.match?(@issue, value))

  defp valid_field?("pr_url", value),
    do: is_nil(value) or match?({:ok, _}, Agentboard.Delivery.Inventory.canonical(value))

  defp valid_field?("to", value), do: slug?(value)

  defp valid_field?("status", value),
    do: value in ~w(open assigned in_progress blocked review done cancelled)

  defp valid_field?("note", value), do: text?(value)
  defp valid_field?("expired", value), do: is_boolean(value)
  defp valid_field?("revision", value), do: is_integer(value) and value > 0
  defp valid_field?("ttl_seconds", value), do: representable_offset?(value)
  defp valid_field?(_, _), do: false

  def representable_offset?(seconds)
      when is_integer(seconds) and seconds > 0 and seconds <= 1_000_000_000_000,
      do: fits?(seconds)

  def representable_offset?(seconds)
      when is_float(seconds) and seconds > 0 and seconds <= 1.0e12 and seconds == seconds,
      do: fits?(seconds)

  def representable_offset?(_), do: false

  defp fits?(seconds) do
    skew = round(seconds * 1_000_000) + 86_400_000_000
    now = DateTime.utc_now()
    _ = DateTime.add(now, skew, :microsecond)
    _ = DateTime.add(now, -skew, :microsecond)
    true
  rescue
    ArgumentError -> false
    ArithmeticError -> false
  end

  defp strings?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
end

