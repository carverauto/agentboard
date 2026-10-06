CREATE FUNCTION board_mutate_task(p_id text, p_action text, p_data jsonb,
  p_actor text, p_model text, p_harness text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  t tasks%ROWTYPE;
  prior tasks%ROWTYPE;
  now_at timestamptz;
  event_id bigint;
  ttl double precision;
  active boolean;
  permitted boolean;
  next_status text;
BEGIN
  PERFORM board_actor(p_actor, p_model, p_harness);
  IF p_id IS NULL OR p_id !~ '^[a-z0-9][a-z0-9_-]{0,127}$' OR jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_input', DETAIL = 'Valid task ID and object payload are required';
  END IF;
  IF p_action = 'create' THEN
    INSERT INTO tasks (id, title, description, priority, repo, labels, issue_url, pr_url)
      VALUES (p_id, p_data->>'title', coalesce(p_data->>'description',''),
        coalesce((p_data->>'priority')::integer,3), p_data->>'repo',
        ARRAY(SELECT jsonb_array_elements_text(coalesce(p_data->'labels','[]'))),
        p_data->>'issue_url', p_data->>'pr_url') RETURNING * INTO t;
  ELSE
    SELECT * INTO t FROM tasks WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'not_found', DETAIL = 'Task not found';
    END IF;
    prior := t;
    -- Evaluate the lease after acquiring this row, never at transaction start.
    now_at := clock_timestamp();
    active := t.status IN ('in_progress','blocked','review');
    permitted := t.status = 'open'
      OR (t.status = 'assigned' AND p_actor IN (t.assignee_id, t.assigner_id))
      OR (active AND t.assignee_id = p_actor AND t.claim_expires_at > now_at);
    IF t.status IN ('done','cancelled') THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Terminal tasks are immutable';
    END IF;
    IF p_data ? 'revision' AND (p_data->>'revision')::bigint <> t.revision THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Task revision changed; reload before editing';
    END IF;
    IF p_action IN ('claim','renew','reclaim') THEN
      ttl := coalesce((p_data->>'ttl_seconds')::double precision,7200);
      IF ttl <= 0 OR ttl IN ('NaN'::double precision,'Infinity'::double precision) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_input', DETAIL = 'Lease must be positive and finite';
      END IF;
    END IF;
    CASE p_action
    WHEN 'assign' THEN
      IF t.status NOT IN ('open','assigned') OR NOT permitted THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Only open or permitted pending work can be assigned';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM agents WHERE id = p_data->>'to') THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_input', DETAIL = 'Assignment target must be registered';
      END IF;
      t.status := 'assigned'; t.assignee_id := p_data->>'to'; t.assigner_id := p_actor;
    WHEN 'claim' THEN
      IF NOT (t.status = 'open' OR (t.status = 'assigned' AND t.assignee_id = p_actor)) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Task is not available to claim; renew or explicitly recover expired work';
      END IF;
      t.status := 'in_progress'; t.assignee_id := p_actor;
      t.claimed_at := now_at; t.claim_expires_at := now_at + ttl * interval '1 second';
    WHEN 'renew' THEN
      IF NOT (active AND permitted) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Only the live owner can renew';
      END IF;
      t.claim_expires_at := now_at + ttl * interval '1 second';
    WHEN 'reclaim' THEN
      IF NOT active OR t.claim_expires_at > now_at THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Only an expired active claim can be reclaimed';
      END IF;
      t.status := 'in_progress'; t.assignee_id := p_actor; t.assigner_id := NULL;
      t.claimed_at := now_at; t.claim_expires_at := now_at + ttl * interval '1 second';
    WHEN 'release' THEN
      IF NOT ((t.status = 'assigned' AND t.assignee_id = p_actor)
          OR (active AND (permitted OR (t.claim_expires_at <= now_at AND p_data->>'expired' = 'true')))) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Release requires the assignee/live owner or explicit expired recovery';
      END IF;
      t.status := 'open'; t.assignee_id := NULL; t.assigner_id := NULL;
      t.claimed_at := NULL; t.claim_expires_at := NULL;
    WHEN 'edit', 'link' THEN
      IF NOT permitted THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Task edit requires permitted ownership';
      END IF;
      IF p_data ? 'title' THEN t.title := p_data->>'title'; END IF;
      IF p_data ? 'description' THEN t.description := p_data->>'description'; END IF;
      IF p_data ? 'priority' THEN t.priority := (p_data->>'priority')::integer; END IF;
      IF p_data ? 'repo' THEN t.repo := p_data->>'repo'; END IF;
      IF p_data ? 'labels' THEN t.labels := ARRAY(SELECT jsonb_array_elements_text(p_data->'labels')); END IF;
      IF p_data ? 'issue_url' THEN t.issue_url := p_data->>'issue_url'; END IF;
      IF p_data ? 'pr_url' THEN t.pr_url := p_data->>'pr_url'; END IF;
    WHEN 'update' THEN
      next_status := p_data->>'status';
      -- Any registered actor may cancel open work or a pending assignment.
      IF NOT permitted AND NOT (t.status = 'assigned' AND next_status = 'cancelled') THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Task update requires permitted ownership';
      END IF;
      IF next_status IS NOT NULL THEN
        IF NOT ((t.status IN ('open','assigned') AND next_status = 'cancelled')
          OR (t.status = 'in_progress' AND next_status IN ('blocked','review','done','cancelled'))
          OR (t.status = 'blocked' AND next_status IN ('in_progress','review','cancelled'))
          OR (t.status = 'review' AND next_status IN ('in_progress','blocked','done','cancelled'))) THEN
          RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'conflict', DETAIL = 'Unsupported status transition';
        END IF;
        IF next_status = 'blocked' AND coalesce(length(btrim(p_data->>'note')),0) = 0 THEN
          RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_input', DETAIL = 'Blocked status requires a reason';
        END IF;
        t.status := next_status;
        IF next_status IN ('done','cancelled') THEN t.claimed_at := NULL; t.claim_expires_at := NULL; END IF;
      ELSIF coalesce(length(btrim(p_data->>'note')),0) = 0 THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_input', DETAIL = 'A note or status is required';
      END IF;
    ELSE
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid_input', DETAIL = 'Unsupported task action';
    END CASE;
    t.revision := t.revision + 1; t.updated_at := now_at;
    UPDATE tasks SET title=t.title, description=t.description, priority=t.priority, repo=t.repo,
      labels=t.labels, issue_url=t.issue_url, pr_url=t.pr_url, status=t.status,
      assignee_id=t.assignee_id, assigner_id=t.assigner_id, claimed_at=t.claimed_at,
      claim_expires_at=t.claim_expires_at, revision=t.revision, updated_at=t.updated_at
      WHERE id=p_id RETURNING * INTO t;
  END IF;
  INSERT INTO task_events(task_id,actor_id,model,harness,kind,body,old_revision,new_revision,data)
    VALUES (p_id,p_actor,p_model,p_harness,p_action,p_data->>'note',prior.revision,t.revision,
      jsonb_build_object('before',CASE WHEN prior.id IS NULL THEN NULL ELSE to_jsonb(prior) END,'after',to_jsonb(t)))
    RETURNING id INTO event_id;
  RETURN jsonb_build_object('task',to_jsonb(t),'event_id',event_id);
END
$$
