defmodule AgentboardWeb.WorkflowHookController do
  @moduledoc "Signature-verified workflow_run cue intake, separate from agent/captain/worker credentials."
  use Phoenix.Controller, formats: [:json]
  alias Agentboard.Delivery.WorkflowMonitor

  def create(conn, _) do
    secret = secret()
    cond do
      !Agentboard.Delivery.Scheduling.enabled?() -> reply(conn, 503, "disabled")
      !is_binary(secret) or byte_size(secret) < 32 -> reply(conn, 503, "unconfigured")
      get_req_header(conn, "x-github-event") not in [["workflow_run"], ["ping"]] -> reply(conn, 400, "unsupported_event")
      true -> verify(conn, secret)
    end
  end

  defp verify(conn, secret) do
    case read_body(conn, length: 1_048_576, read_length: 1_048_576, read_timeout: 5000) do
      {:ok, body, conn} ->
        expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
        with [signature] <- get_req_header(conn, "x-hub-signature-256"),
             true <- byte_size(signature) == byte_size(expected) and Plug.Crypto.secure_compare(signature, expected),
             {:ok, payload} <- Jason.decode(body) do
          if get_req_header(conn, "x-github-event") == ["ping"],
            do: reply(conn, 200, "pong"), else: intake(conn, payload)
        else
          _ -> reply(conn, 401, "invalid_signature_or_body")
        end
      {:more, _, conn} -> reply(conn, 413, "too_large")
      {:error, _} -> reply(conn, 400, "invalid_body")
    end
  end

  defp intake(conn, %{"action" => "completed", "repository" => %{"full_name" => repository},
      "workflow_run" => %{"id" => run_id}}) when is_binary(repository) and is_integer(run_id) and run_id > 0 do
    repos = Application.get_env(:agentboard, :workflow_repositories, [])
    if repository in repos && Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repository) do
      case WorkflowMonitor.queue(repository, Integer.to_string(run_id)) do
        {:ok, queued} -> conn |> put_status(202) |> json(queued)
        {:error, _, _} -> reply(conn, 503, "unavailable")
      end
    else
      reply(conn, 403, "repository_not_watched")
    end
  end
  defp intake(conn, _), do: reply(conn, 400, "invalid_completed_run")

  defp secret do
    case Application.get_env(:agentboard, :workflow_webhook_secret_file) do
      path when is_binary(path) -> case File.read(path) do
        {:ok, value} -> String.trim_trailing(value, "\n")
        {:error, _} -> nil
      end
      _ -> nil
    end
  end
  defp reply(conn, code, status), do: conn |> put_status(code) |> json(%{status: status})
end
