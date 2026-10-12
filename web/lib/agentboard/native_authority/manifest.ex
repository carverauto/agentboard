defmodule Agentboard.NativeAuthority.Manifest do
  @moduledoc "Closed captain-reviewed descriptor. Inventory is an assertion, never remote process proof."
  @max_safe 9_007_199_254_740_991
  @token ~r/\A[A-Za-z0-9_.:-]{1,128}\z/
  @uuid ~r/\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/
  @digest ~r/\A[a-f0-9]{64}\z/

  def valid?(m) do
    exact?(
      m,
      ~w(manifest_version id worker_id host_id enrollment_revision binding_epoch session_id pane_id socket_path initialize_approved endpoint recipient peer)
    ) and
      m["manifest_version"] === 1 and token?(m["id"]) and Agentboard.Input.slug?(m["worker_id"]) and
      Enum.all?(~w(host_id session_id pane_id), &ascii?(m[&1], 240)) and
      safe_positive?(m["enrollment_revision"]) and safe_positive?(m["binding_epoch"]) and
      socket?(m["socket_path"]) and m["initialize_approved"] == true and
      endpoint?(m["endpoint"]) and recipient?(m["recipient"], m) and peer?(m["peer"])
  end

  def exact?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  def safe?(n), do: is_integer(n) and n >= 0 and n <= @max_safe
  def safe_positive?(n), do: safe?(n) and n > 0
  def token?(s), do: is_binary(s) and Regex.match?(@token, s)
  defp uuid?(s), do: is_binary(s) and Regex.match?(@uuid, s)
  defp digest?(s), do: is_binary(s) and Regex.match?(@digest, s)

  defp ascii?(s, max),
    do: is_binary(s) and byte_size(s) in 1..max and Regex.match?(~r/\A[\x20-\x7e]+\z/, s)

  defp socket?(s) do
    ascii?(s, 4096) and String.starts_with?(s, "/") and s != "/" and
      Enum.all?(tl(String.split(s, "/")), &(&1 not in ["", ".", ".."]))
  end

  defp endpoint?(e) do
    exact?(
      e,
      ~w(serverId endpointId generation profile nativeVersion protocolSource schemaSha256 experimentalApi queueApi)
    ) and
      token?(e["serverId"]) and token?(e["endpointId"]) and e["generation"] == "" and
      e["profile"] == "codex-durable-advisory-v1" and e["nativeVersion"] == "0.162.0" and
      e["protocolSource"] == "rust-v0.162.0" and digest?(e["schemaSha256"]) and
      e["experimentalApi"] == true and e["queueApi"] == true
  end

  defp recipient?(r, m) do
    exact?(r, ~w(threadId identityKind enrollmentRevision bindingEpoch persistent topLevel)) and
      uuid?(r["threadId"]) and r["identityKind"] == "durable-conversation-v1" and
      r["enrollmentRevision"] === m["enrollment_revision"] and
      r["bindingEpoch"] === m["binding_epoch"] and
      r["persistent"] == true and r["topLevel"] == true
  end

  defp peer?(p) do
    exact?(p, ~w(pid uid bootId startTicks executableSha256)) and
      is_integer(p["pid"]) and p["pid"] in 1..2_147_483_647 and
      is_integer(p["uid"]) and p["uid"] in 0..4_294_967_295 and
      uuid?(p["bootId"]) and safe_positive?(p["startTicks"]) and digest?(p["executableSha256"])
  end

  # Maps have sorted keys; valid descriptors contain only printable ASCII strings,
  # booleans and safe integers. Jason's default does not HTML-escape strings.
  def canonical(value) when is_map(value),
    do:
      "{" <>
        (value
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)) <> "}"

  def canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  def canonical(value), do: Jason.encode!(value)
  def sha256(value), do: :crypto.hash(:sha256, canonical(value)) |> Base.encode16(case: :lower)
end
