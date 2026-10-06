CREATE FUNCTION board_message(p_id bigint,p_data jsonb,p_actor text,p_model text,p_harness text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE m messages%ROWTYPE;
BEGIN
  PERFORM board_actor(p_actor,p_model,p_harness);
  IF p_id IS NULL THEN
    INSERT INTO messages(sender_id,model,harness,recipient_id,task_id,body)
      VALUES(p_actor,p_model,p_harness,p_data->>'to',p_data->>'task',p_data->>'body') RETURNING * INTO m;
  ELSE
    SELECT * INTO m FROM messages WHERE id=p_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='not_found',DETAIL='Message not found';
    END IF;
    IF m.recipient_id IS NULL OR m.recipient_id <> p_actor THEN
      RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Only the addressed recipient may acknowledge a message';
    END IF;
    IF m.read_at IS NULL THEN
      UPDATE messages SET read_at=clock_timestamp(),read_model=p_model,read_harness=p_harness WHERE id=p_id RETURNING * INTO m;
    END IF;
  END IF;
  RETURN jsonb_build_object('message',to_jsonb(m));
END $$
-- statement-break
CREATE FUNCTION board_handoff_task(p_id text,p_data jsonb,p_actor text,p_model text,p_harness text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE t tasks%ROWTYPE; prior tasks%ROWTYPE; stamp timestamptz; event_id bigint; message_id bigint;
BEGIN
  PERFORM board_actor(p_actor,p_model,p_harness);
  SELECT * INTO t FROM tasks WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='not_found',DETAIL='Task not found';
  END IF;
  stamp:=clock_timestamp(); prior:=t;
  IF t.status NOT IN ('in_progress','blocked','review') OR t.assignee_id<>p_actor OR t.claim_expires_at<=stamp THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Handoff requires the live owner';
  END IF;
  IF p_data ? 'revision' AND (p_data->>'revision')::bigint<>t.revision THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Task revision changed';
  END IF;
  IF coalesce(length(btrim(p_data->>'note')),0)=0 OR NOT EXISTS(SELECT 1 FROM agents WHERE id=p_data->>'to') THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='invalid_input',DETAIL='Handoff requires a reason and registered recipient';
  END IF;
  UPDATE tasks SET status='assigned',assignee_id=p_data->>'to',assigner_id=p_actor,claimed_at=NULL,claim_expires_at=NULL,
    revision=revision+1,updated_at=stamp WHERE id=p_id RETURNING * INTO t;
  INSERT INTO task_events(task_id,actor_id,model,harness,kind,body,old_revision,new_revision,data)
    VALUES(p_id,p_actor,p_model,p_harness,'handoff',p_data->>'note',prior.revision,t.revision,
      jsonb_build_object('before',to_jsonb(prior),'after',to_jsonb(t))) RETURNING id INTO event_id;
  INSERT INTO messages(sender_id,model,harness,recipient_id,task_id,body)
    VALUES(p_actor,p_model,p_harness,p_data->>'to',p_id,p_data->>'note') RETURNING id INTO message_id;
  RETURN jsonb_build_object('task',to_jsonb(t),'event_id',event_id,'message_id',message_id);
END $$
-- statement-break
CREATE FUNCTION board_heartbeat(p_data jsonb,p_actor text,p_model text,p_harness text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a agents%ROWTYPE;
BEGIN
  PERFORM board_actor(p_actor,p_model,p_harness);
  IF p_data->>'status' IS NULL OR p_data->>'status' NOT IN ('busy','idle') THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='invalid_input',DETAIL='Heartbeat status must be busy or idle';
  END IF;
  IF p_data->>'task' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM tasks WHERE id=p_data->>'task' AND assignee_id=p_actor) THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Current task must exist and belong to this agent';
  END IF;
  UPDATE agents SET reported_status=p_data->>'status',current_task_id=p_data->>'task',last_heartbeat=clock_timestamp(),
    model=p_model,metadata=CASE WHEN p_data ? 'backend' THEN metadata || jsonb_build_object('backend',p_data->>'backend') ELSE metadata END,
    updated_at=clock_timestamp() WHERE id=p_actor RETURNING * INTO a;
  RETURN jsonb_build_object('agent',to_jsonb(a));
END $$
