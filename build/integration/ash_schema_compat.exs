# Verify persisted schema-4 records through the new domain's public read actions.
# Wrong field types, table names or default selections must fail independently
# of the old SQL API's acceptance coverage.
Application.ensure_all_started(:agentboard)

alias Agentboard.Board.Resources, as: Board
alias Agentboard.Evidence.Resources, as: Evidence

[%{id: "worker", harness: "codex", capabilities: [], metadata: %{}}] = Ash.read!(Board.Agent)
[%{id: "sample", status: "open", revision: 1, assignee_id: nil}] = Ash.read!(Board.Task)
[%{task_id: "sample", actor_id: "worker", kind: "created", new_revision: 1}] = Ash.read!(Board.TaskEvent)
[%{task_id: "sample", body: "Investigated TLS", read_at: nil}] = Ash.read!(Board.Message)

[%{id: document_id, html: %Ash.NotLoaded{}, title: "TLS flow"}] = Ash.read!(Evidence.Document)
[%{id: ^document_id, html: "<!doctype html><p>café &amp; TLS</p>"}] =
  Evidence.Document |> Ash.Query.select([:html]) |> Ash.read!()

[%{id: report_id, raw: %Ash.NotLoaded{}, schema_version: 6}] = Ash.read!(Evidence.QuotaReport)
[%{id: ^report_id, raw: %{"schema_version" => 6, "providers" => %{}}}] =
  Evidence.QuotaReport |> Ash.Query.select([:raw]) |> Ash.read!()

[%{id: observation_id, report_id: ^report_id, provider_data: %{"status" => "ok"}}] =
  Ash.read!(Evidence.QuotaObservation)
[%{observation_id: ^observation_id, window_id: "five-hour", data: %{"remaining" => 42}}] =
  Ash.read!(Evidence.QuotaWindow)
[%{observation_id: ^observation_id, scope: "fixture-model", data: %{"available" => true}}] =
  Ash.read!(Evidence.QuotaScope)

IO.puts("Existing board/evidence IDs, typed fields and unselected HTML/raw evidence preserved")
