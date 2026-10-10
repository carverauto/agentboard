defmodule Agentboard.Mattermost.DecisionConversations do
  @moduledoc "Canonical decision pointers, scoped replies and durable no-blind-retry submission."
  alias Agentboard.{Auth, Repo}
  alias Agentboard.Auth.{APIAuthPolicy, Credential}
  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Board.Resources.{Agent, Task}
  alias Agentboard.Decisions.Request
  alias Agentboard.Mattermost.{Inbound, InboundHTTP, InboundStore, Participation}
  alias Agentboard.Mattermost.DecisionConversations.{Intent, Payload}
  require Ash.Query

  def notify(principal, id, data) do
    with :ok <- enforced(principal, "agent"),
         :ok <- shape(data, ~w(channel_id)),
         :ok <- valid_id(id),
         true <- APIAuthPolicy.channel_id?(data["channel_id"]),
         :ok <- Participation.authorize_local(principal, data["channel_id"]),
         {:ok, cfg} <- source_config(),
         {:ok, intent} <- Ops.transaction(fn -> prepare_notice(principal, id, data, cfg) end) do
      deliver(intent, principal, notice_body(intent))
    else
      false -> {:error, "invalid_input", "Valid channel_id required"}
      error -> error
    end
  end

  def reply(principal, id, data) do
    with :ok <- enforced(principal, "coordinator_participant"),
         :ok <- shape(data, ~w(inbox_id version retry_key body)),
         :ok <- valid_id(id),
         :ok <- valid_id(data["inbox_id"]),
         true <-
           hash?(data["version"]) and text?(data["retry_key"], 128) and
             text?(data["body"], 16_000),
         {:ok, cfg} <- source_config(),
         {:ok, intent} <- Ops.transaction(fn -> prepare_reply(principal, id, data, cfg) end) do
      deliver(intent, principal, data["body"])
    else
      false ->
        {:error, "invalid_input", "Exact version, bounded retry_key and UTF-8 body required"}

      error ->
        error
    end
  end

  def show(principal, id) do
    with :ok <- enforced(principal), :ok <- valid_id(id), {:ok, cfg} <- source_config() do
      Ops.transaction(fn ->
        current!(principal)
        request = Ops.fetch!(Request, id, "Decision not found")

        intents =
          Intent
          |> Ash.Query.filter(decision_id == ^id)
          |> Ash.Query.sort(created_at: :asc)
          |> Ash.read!()

        # No receipt existence probe into another decision's private conversation.
        unless principal.agent_id == request.requester_id or
                 (principal.scope == "coordinator_participant" and
                    principal.agent_id == Application.get_env(:agentboard, :coordinator_id)),
               do: Ops.reject("forbidden", "Conversation belongs to another identity")

        Enum.each(intents, &read_admission!(&1, principal, cfg))
        %{intents: Enum.map(intents, &public/1)}
      end)
    end
  end

  def reconcile(principal, id, data) do
    with :ok <- enforced(principal),
         :ok <- valid_id(id),
         :ok <- shape(data, ~w(intent_id)),
         :ok <- valid_id(data["intent_id"]),
         {:ok, cfg} <- source_config(),
         {:ok, intent} <-
           Ops.transaction(fn ->
             current!(principal)
             intent = Ops.fetch!(Intent, data["intent_id"], "Conversation intent not found")

             unless intent.decision_id == id,
               do: Ops.reject("forbidden", "Intent belongs to another decision")

             read_admission!(intent, principal, cfg)
             intent
           end) do
      if intent.state in ~w(prepared blocked sent) or not is_nil(intent.duplicate_observed_at) do
        {:ok, %{intent: public(intent)}}
      else
        with {:ok, bot} <- Participation.authorize(principal, intent.channel_id),
             :ok <- current_source(intent, bot, cfg),
             {:ok, _} <-
               Ops.transaction(fn ->
                 current!(principal)
                 read_admission!(intent, principal, cfg)
                 source_admission!(intent, bot, cfg)
               end) do
          case find_posts(bot, intent, 0, []) do
            {:ok, [post]} -> retain_sent(intent, post)
            {:ok, []} -> retain_uncertain(intent, "post_not_observed")
            {:ok, posts} -> retain_duplicate(intent, posts)
            {:error, reason} -> retain_uncertain(intent, reason)
          end
        end
      end
    end
  end

  defp prepare_notice(principal, id, data, cfg) do
    current!(principal)
    request = locked_request!(id)
    task = Ops.fetch!(Task, request.task_id, "Task not found")

    unless principal.agent_id == request.requester_id,
      do: Ops.reject("forbidden", "Only the canonical requester may notify")

    channel = data["channel_id"]

    unless channel == Application.get_env(:agentboard, :coordinator_chat_channel_id),
      do: Ops.reject("forbidden", "Channel is not the configured coordinator route")

    repo = canonical_repo(task.repo)

    unless repo == cfg.repo,
      do: Ops.reject("forbidden", "Task is outside the configured inbound repository")

    coordinator = Application.get_env(:agentboard, :coordinator_id)
    enrolled!(principal.agent_id, repo)
    enrolled!(coordinator, repo)
    source = InboundStore.source(cfg)
    key = digest(["notify", id, principal.agent_id, coordinator, source, channel])

    prior =
      Intent |> Ash.Query.filter(decision_id == ^id and operation == "notify") |> Ash.read_one!()

    if prior do
      unless prior.request_hash == key,
        do: Ops.reject("conflict", "Retained notice has different routing or identity")

      prior
    else
      open_request!(request, task, ~w(open))
      actor = actor(principal)
      stamp = Ops.now()
      intent_id = Ash.UUID.generate()

      attrs = %{
        id: intent_id,
        decision_id: id,
        operation: "notify",
        actor_id: principal.agent_id,
        credential_id: principal.credential_id,
        channel_ids: Map.get(principal, :channel_ids, []),
        request_key: "decision-notify:" <> id,
        request_hash: key,
        source: source,
        repo: repo,
        channel_id: channel,
        root_id: "",
        recipient_id: coordinator,
        task_id: task.id,
        bot_user_id: nil,
        msg_id: intent_id,
        state: "prepared",
        created_at: stamp,
        updated_at: stamp
      }

      body = notice_body(attrs)

      notice =
        Ops.send_message(
          actor,
          %{
            "to" => coordinator,
            "task" => task.id,
            "body" => body,
            "triage" => %{
              "version" => 1,
              "category" => "needs_judgment",
              "attention" => "captain",
              "source" => %{"kind" => "decision_request", "request_id" => id}
            }
          },
          stamp,
          false
        )

      # This source owns its sole typed MM projection; preserve the ordinary board wake.
      Agentboard.WakeIntents.capture_message(notice, actor)

      attrs =
        Map.merge(attrs, %{
          board_message_id: notice.id,
          payload_hash: Payload.digest(Payload.make(attrs, body))
        })

      Ops.create(Intent, :record, attrs, internal_actor(principal))
    end
  end

  defp prepare_reply(principal, id, data, cfg) do
    current!(principal)
    request = locked_request!(id)
    task = Ops.fetch!(Task, request.task_id, "Task not found")
    repo = canonical_repo(task.repo)
    enrolled!(principal.agent_id, repo)
    enrolled!(request.requester_id, repo)

    parent =
      Intent |> Ash.Query.filter(decision_id == ^id and operation == "notify") |> Ash.read_one!()

    unless parent && parent.state == "sent" && is_nil(parent.duplicate_observed_at) &&
             parent.recipient_id == principal.agent_id,
           do: Ops.reject("conflict", "Verified canonical notification required")

    local_channel!(principal, parent.channel_id)

    unless repo == cfg.repo && parent.source == InboundStore.source(cfg),
      do: Ops.reject("forbidden", "Source belongs to another configured service or repository")

    source_row!(parent, principal.agent_id, data["inbox_id"], data["version"])

    hash =
      digest([
        "reply",
        id,
        principal.agent_id,
        data["inbox_id"],
        data["version"],
        data["body"],
        parent.source,
        parent.channel_id,
        parent.post_id
      ])

    lock_key(principal.agent_id, data["retry_key"])

    prior =
      Intent
      |> Ash.Query.filter(
        actor_id == ^principal.agent_id and operation == "reply" and
          request_key == ^data["retry_key"]
      )
      |> Ash.read_one!()

    if prior do
      unless prior.request_hash == hash,
        do: Ops.reject("conflict", "Retry key has different source or content")

      prior
    else
      open_request!(request, task, ~w(open answered))
      stamp = Ops.now()
      intent_id = Ash.UUID.generate()

      attrs = %{
        id: intent_id,
        decision_id: id,
        operation: "reply",
        actor_id: principal.agent_id,
        credential_id: principal.credential_id,
        channel_ids: principal.channel_ids,
        request_key: data["retry_key"],
        request_hash: hash,
        source: parent.source,
        repo: repo,
        channel_id: parent.channel_id,
        root_id: parent.post_id,
        recipient_id: request.requester_id,
        task_id: task.id,
        board_message_id: parent.board_message_id,
        parent_id: parent.id,
        inbox_id: data["inbox_id"],
        inbox_version: data["version"],
        bot_user_id: nil,
        msg_id: intent_id,
        state: "prepared",
        created_at: stamp,
        updated_at: stamp
      }

      attrs = Map.put(attrs, :payload_hash, Payload.digest(Payload.make(attrs, data["body"])))
      Ops.create(Intent, :record, attrs, internal_actor(principal))
    end
  end

  defp deliver(%{state: state} = intent, _principal, _body) when state != "prepared",
    do: {:ok, %{intent: public(intent)}}

  defp deliver(intent, principal, body) do
    # Any failure before the durable submitting transition is safe to resume with
    # identical input. A network error after transition can never reset this state.
    with {:ok, cfg} <- source_config(),
         {:ok, _} <-
           Ops.transaction(fn ->
             current!(principal)
             read_admission!(intent, principal, cfg)
           end),
         {:ok, bot} <- Participation.authorize(principal, intent.channel_id),
         :ok <- current_source(intent, bot, cfg),
         :ok <- inspect_reply_source(intent, bot),
         {:ok, {admitted, post?}} <-
           Ops.transaction(fn -> admit(intent, principal, cfg, bot, body) end) do
      if post? do
        payload = Payload.make(admitted, body)

        case InboundHTTP.post_agent(bot, payload) do
          {:ok, post} ->
            if Inbound.valid_post?(post) and Payload.matches?(admitted, post),
              do: retain_sent(admitted, post),
              else: retain_uncertain(admitted, "unverified_acknowledgment")

          _ ->
            retain_uncertain(admitted, "submission_outcome_unknown")
        end
      else
        {:ok, %{intent: public(admitted)}}
      end
    else
      {:error, code, _} when code in ~w(unavailable) ->
        retain_prepared(intent, "channel_preflight_unavailable")

      error ->
        error
    end
  end

  defp admit(intent, principal, cfg, bot, body) do
    current!(principal)
    request = locked_request!(intent.decision_id)
    task = Ops.fetch!(Task, request.task_id, "Task not found")
    locked_intent = lock_intent!(intent.id)
    read_admission!(locked_intent, principal, cfg)
    source_admission!(locked_intent, bot, cfg)
    captured = credential_principal!(locked_intent.credential_id)

    unless captured.agent_id == locked_intent.actor_id &&
             principal.agent_id == locked_intent.actor_id,
           do: Ops.reject("forbidden", "Only the captured actor may submit this intent")

    local_channel!(captured, locked_intent.channel_id)

    unless canonical_repo(task.repo) == locked_intent.repo && task.id == locked_intent.task_id,
      do: Ops.reject("conflict", "Canonical repository changed")

    enrolled!(locked_intent.actor_id, locked_intent.repo)
    enrolled!(locked_intent.recipient_id, locked_intent.repo)

    if locked_intent.state != "prepared" do
      {locked_intent, false}
    else
      open_request!(
        request,
        task,
        if(locked_intent.operation == "notify", do: ~w(open), else: ~w(open answered))
      )

      unless Application.get_env(:agentboard, :coordinator_chat_channel_id) ==
               locked_intent.channel_id,
             do: Ops.reject("forbidden", "Coordinator route changed")

      if locked_intent.operation == "reply" do
        parent = Ops.fetch!(Intent, locked_intent.parent_id, "Notification not found")

        source_row!(
          parent,
          principal.agent_id,
          locked_intent.inbox_id,
          locked_intent.inbox_version
        )
      end

      unless Payload.digest(Payload.make(locked_intent, body)) == locked_intent.payload_hash,
        do: Ops.reject("conflict", "Payload no longer matches its retained intent")

      stamp = Ops.now()

      {Ops.update(
         locked_intent,
         :transition,
         %{
           state: "submitting",
           reason: nil,
           bot_user_id: bot.bot_id,
           submitted_at: stamp,
           updated_at: stamp
         },
         internal_actor(principal)
       ), true}
    end
  end

  defp inspect_reply_source(%{operation: "notify"}, _bot), do: :ok

  defp inspect_reply_source(intent, bot) do
    parent = Ash.get!(Intent, intent.parent_id)

    with {:ok, post} <- InboundHTTP.post(bot, parent.post_id),
         true <-
           Inbound.valid_post?(post) and Payload.matches?(parent, post) and
             InboundStore.version(post) == intent.inbox_version and
             parent.post_version == intent.inbox_version do
      :ok
    else
      _ -> {:error, "conflict", "Exact original notification source is unavailable or changed"}
    end
  end

  defp source_row!(parent, recipient, id, version) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT 1 FROM mattermost_inbox WHERE id=$1::text::uuid AND version=$2 AND worker_id=$3
          AND repo=$4 AND source=$5 AND channel_id=$6 AND post_id=$7 AND task_id=$8
          AND sender_agent_id=$9 AND msg_id=$10
        """,
        [
          id,
          version,
          recipient,
          parent.repo,
          parent.source,
          parent.channel_id,
          parent.post_id,
          parent.task_id,
          parent.actor_id,
          parent.msg_id
        ]
      )

    unless rows != [] && parent.state == "sent" && is_nil(parent.duplicate_observed_at) &&
             parent.post_version == version,
           do:
             Ops.reject(
               "forbidden",
               "Exact version is not the canonical notification in this recipient inbox"
             )
  end

  defp read_admission!(intent, principal, cfg) do
    local_channel!(principal, intent.channel_id)

    unless intent.source == InboundStore.source(cfg) && intent.repo == cfg.repo,
      do: Ops.reject("forbidden", "Retained destination is not the current configured source")

    coordinator = Application.get_env(:agentboard, :coordinator_id)
    request = Ops.fetch!(Request, intent.decision_id, "Decision not found")

    expected_coordinator =
      if intent.operation == "notify", do: intent.recipient_id, else: intent.actor_id

    unless expected_coordinator == coordinator &&
             (principal.agent_id == request.requester_id or
                (principal.scope == "coordinator_participant" && principal.agent_id == coordinator)),
           do: Ops.reject("forbidden", "Conversation belongs to another coordinator or requester")

    enrolled!(principal.agent_id, intent.repo)
    :ok
  end

  defp current_source(intent, bot, cfg) do
    with {:ok, current} <- source_config(),
         true <-
           current.repo == cfg.repo and current.base_url == cfg.base_url and
             bot.base_url == current.base_url and
             InboundStore.source(current) == intent.source and
             Plug.Crypto.secure_compare(current.token, bot.token) and
             (is_nil(intent.bot_user_id) or bot.bot_id == intent.bot_user_id) and
             Application.get_env(:agentboard, :coordinator_chat_channel_id) == intent.channel_id do
      :ok
    else
      _ -> {:error, "forbidden", "Pinned source, bot or coordinator route changed"}
    end
  end

  defp source_admission!(intent, bot, cfg) do
    case current_source(intent, bot, cfg) do
      :ok -> :ok
      {:error, code, message} -> Ops.reject(code, message)
    end
  end

  # A sole match is not enough when the bounded history remains incomplete.
  # Proven multiplicity short-circuits below; budget exhaustion never adopts.
  defp find_posts(_cfg, _intent, 5, _matches), do: {:error, "history_budget_exhausted"}

  defp find_posts(cfg, intent, page, matches) do
    case InboundHTTP.page(cfg, intent.channel_id, page) do
      {:ok, %{"order" => order, "posts" => posts}}
      when is_list(order) and is_map(posts) and length(order) <= 60 and map_size(posts) <= 60 ->
        if Enum.all?(order, fn id ->
             Inbound.valid_post?(posts[id]) and posts[id]["id"] == id and
               posts[id]["channel_id"] == intent.channel_id
           end) do
          found = Enum.filter(Enum.map(order, &posts[&1]), &Payload.matches?(intent, &1))
          result = Enum.uniq_by(matches ++ found, & &1["id"])

          if length(result) >= 2 or length(order) < 60,
            do: {:ok, result},
            else: find_posts(cfg, intent, page + 1, result)
        else
          {:error, "history_incomplete"}
        end

      _ ->
        {:error, "history_unavailable"}
    end
  end

  defp retain_sent(intent, post) do
    Ops.transaction(fn ->
      row = lock_intent!(intent.id)

      cond do
        row.state == "sent" or not is_nil(row.duplicate_observed_at) ->
          %{intent: public(row)}

        row.state not in ~w(submitting uncertain) ->
          Ops.reject("conflict", "Intent has not been submitted")

        not Payload.matches?(row, post) ->
          Ops.reject("conflict", "Remote receipt does not match intent")

        true ->
          stamp = Ops.now()

          metadata =
            Map.take(
              post,
              ~w(id channel_id user_id root_id create_at update_at edit_at delete_at)
            )

          changed =
            Ops.update(
              row,
              :transition,
              %{
                state: "sent",
                reason: nil,
                post_id: post["id"],
                post_version: InboundStore.version(post),
                post_metadata: metadata,
                verified_at: stamp,
                updated_at: stamp
              },
              system_actor()
            )

          %{intent: public(changed)}
      end
    end)
  end

  defp retain_uncertain(intent, reason) do
    Ops.transaction(fn ->
      row = lock_intent!(intent.id)

      row =
        if row.state in ~w(submitting uncertain) and is_nil(row.duplicate_observed_at),
          do:
            Ops.update(
              row,
              :transition,
              %{state: "uncertain", reason: reason, updated_at: Ops.now()},
              system_actor()
            ),
          else: row

      %{intent: public(row)}
    end)
  end

  defp retain_duplicate(intent, posts) do
    Ops.transaction(fn ->
      row = lock_intent!(intent.id)

      if is_nil(row.duplicate_observed_at) do
        stamp = Ops.now()

        attrs = %{
          duplicate_observed_at: stamp,
          duplicate_post_ids: posts |> Enum.map(& &1["id"]) |> Enum.uniq() |> Enum.take(20),
          updated_at: stamp
        }

        # Keep an already committed sent receipt immutable, while preserving a
        # racing duplicate observation independently. Public state becomes uncertain.
        attrs =
          if row.state == "sent",
            do: attrs,
            else: Map.merge(attrs, %{state: "uncertain", reason: "duplicate_posts_observed"})

        %{intent: public(Ops.update(row, :transition, attrs, system_actor()))}
      else
        %{intent: public(row)}
      end
    end)
  end

  defp retain_prepared(intent, reason) do
    Ops.transaction(fn ->
      row = lock_intent!(intent.id)

      row =
        if row.state == "prepared",
          do:
            Ops.update(row, :transition, %{reason: reason, updated_at: Ops.now()}, system_actor()),
          else: row

      %{intent: public(row)}
    end)
  end

  defp locked_request!(id) do
    request = Ops.fetch!(Request, id, "Decision not found")
    Ops.lock_task(request.task_id)
    Repo.statement!("SELECT id FROM decision_requests WHERE id=$1::text::uuid FOR UPDATE", [id])
    Ops.fetch!(Request, id, "Decision not found")
  end

  defp lock_intent!(id) do
    Repo.statement!(
      "SELECT id FROM decision_conversation_intents WHERE id=$1::text::uuid FOR UPDATE",
      [id]
    )

    Ops.fetch!(Intent, id, "Conversation intent not found")
  end

  defp lock_key(actor, key) do
    <<lock::signed-64, _::binary>> =
      :crypto.hash(:sha256, "decision-conversation:" <> actor <> ":" <> key)

    Repo.statement!("SELECT pg_advisory_xact_lock($1)", [lock])
  end

  defp open_request!(request, task, statuses) do
    unless request.status in statuses && task.assignee_id == request.requester_id &&
             task.status in ~w(in_progress blocked review),
           do:
             Ops.reject(
               "conflict",
               "Canonical request or task ownership no longer permits this message"
             )
  end

  defp enrolled!(id, repo) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT 1 FROM cooperation_subscriptions s JOIN agents a ON a.id=s.id
          JOIN cooperation_bindings b ON b.id=s.id
        WHERE s.id=$1 AND NOT s.revoked AND a.retired_at IS NULL AND $2=ANY(s.repos)
        """,
        [id, repo]
      )

    if rows == [],
      do:
        Ops.reject(
          "forbidden",
          "Active recipient enrollment in the canonical repository required"
        )
  end

  defp current!(principal) do
    current = credential_principal!(principal.credential_id)

    unless Map.take(current, [:agent_id, :scope, :model, :harness, :channel_ids]) ==
             Map.take(Map.put_new(principal, :channel_ids, []), [
               :agent_id,
               :scope,
               :model,
               :harness,
               :channel_ids
             ]),
           do: Ops.reject("forbidden", "Current authenticated principal changed")

    current
  end

  defp credential_principal!(id) do
    credential = Ops.fetch!(Credential, id, "Credential unavailable", "forbidden")
    agent = Ops.fetch!(Agent, credential.agent_id, "Identity unavailable", "forbidden")

    unless APIAuthPolicy.credential_allowed?(
             credential,
             agent,
             Application.get_env(:agentboard, :coordinator_id)
           ),
           do: Ops.reject("forbidden", "Captured credential is no longer authorized")

    %{
      credential_id: credential.id,
      agent_id: agent.id,
      scope: credential.scope,
      model: agent.model,
      harness: agent.harness,
      channel_ids: credential.channel_ids
    }
  end

  defp local_channel!(principal, channel) do
    case Participation.authorize_local(principal, channel) do
      :ok -> :ok
      {:error, code, message} -> Ops.reject(code, message)
    end
  end

  defp source_config do
    case Inbound.base_config() do
      {:ok, cfg} ->
        {:ok, cfg}

      _ ->
        {:error, "unavailable",
         "Typed decision chat requires configured inbound service and repository"}
    end
  end

  defp notice_body(intent),
    do:
      "@#{intent.recipient_id} Decision #{intent.decision_id} awaits captain. Read agentboard decision show #{intent.decision_id}. Chat is a pointer; the board retains decision authority."

  defp actor(principal),
    do: %{
      "agent" => principal.agent_id,
      "model" => principal.model,
      "harness" => principal.harness
    }

  defp internal_actor(principal),
    do: Map.put(actor(principal), :decision_conversation_internal, true)

  defp system_actor,
    do: %{
      "agent" => "mattermost-conversations",
      "model" => "system",
      "harness" => "ash",
      :decision_conversation_internal => true
    }

  defp canonical_repo(repo) when is_binary(repo),
    do:
      if(String.contains?(repo, "/"),
        do: String.downcase(repo),
        else: "carverauto/" <> String.downcase(repo)
      )

  defp canonical_repo(_), do: nil

  defp digest(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  defp valid_id(value),
    do:
      if(is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value)),
        do: :ok,
        else: {:error, "invalid_input", "Canonical UUID required"}
      )

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, <<0>>)

  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp shape(value, keys),
    do:
      if(is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys),
        do: :ok,
        else: {:error, "invalid_input", "Exact conversation fields required"}
      )

  defp enforced(principal, scope \\ nil) do
    if Auth.mode() == "enforce" and is_map(principal) and
         principal[:scope] in ~w(agent coordinator_participant) and
         (is_nil(scope) or principal.scope == scope),
       do: :ok,
       else: {:error, "forbidden", "Enforced authenticated conversation participation required"}
  end

  defp public(intent) do
    value =
      intent
      |> Ops.public()
      |> Map.drop(~w(request_hash payload_hash credential_id channel_ids post_metadata))

    if is_nil(intent.duplicate_observed_at),
      do: value,
      else: Map.merge(value, %{"state" => "uncertain", "reason" => "duplicate_posts_observed"})
  end
end
