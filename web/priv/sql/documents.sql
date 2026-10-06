CREATE FUNCTION board_document_meta(d task_documents) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('id',d.id,'task_id',d.task_id,'source_agent_id',d.source_agent_id,
    'model',d.model,'harness',d.harness,'kind',d.kind,'title',d.title,'digest',d.digest,
    'pr_url',d.pr_url,'source_revision',d.source_revision,'proposal_name',d.proposal_name,'created_at',d.created_at)
$$
-- statement-break
CREATE FUNCTION board_document(p_id text,p_data jsonb,p_digest text,p_actor text,p_model text,p_harness text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE t tasks%ROWTYPE; d task_documents%ROWTYPE;
BEGIN
  PERFORM board_actor(p_actor,p_model,p_harness);
  SELECT * INTO t FROM tasks WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='not_found',DETAIL='Task not found';
  END IF;
  SELECT * INTO d FROM task_documents WHERE task_id=p_id AND source_agent_id=p_actor AND digest=p_digest;
  IF FOUND THEN
    RETURN jsonb_build_object('document',board_document_meta(d),'idempotent',true);
  END IF;
  IF t.status NOT IN ('in_progress','blocked','review') OR t.assignee_id IS DISTINCT FROM p_actor
      OR t.claim_expires_at IS NULL OR t.claim_expires_at<=clock_timestamp() THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='conflict',DETAIL='Documentation upload requires a live task owner';
  END IF;
  IF (SELECT count(*) FROM task_documents WHERE task_id=p_id)>=100 THEN
    RAISE EXCEPTION USING ERRCODE='P0001',MESSAGE='invalid_input',DETAIL='Task already has 100 documentation versions';
  END IF;
  INSERT INTO task_documents(task_id,source_agent_id,model,harness,kind,title,html,digest,pr_url,source_revision,proposal_name)
  VALUES(p_id,p_actor,p_model,p_harness,p_data->>'kind',p_data->>'title',p_data->>'html',p_digest,
    p_data->>'pr_url',p_data->>'source_revision',p_data->>'proposal_name') RETURNING * INTO d;
  INSERT INTO task_events(task_id,actor_id,model,harness,kind,body,old_revision,new_revision,data)
  VALUES(p_id,p_actor,p_model,p_harness,'note','Documentation: '||d.title,t.revision,t.revision+1,
    jsonb_build_object('document_id',d.id,'document_kind',d.kind,'digest',d.digest,'pr_url',d.pr_url));
  UPDATE tasks SET updated_at=clock_timestamp(),revision=revision+1 WHERE id=p_id;
  PERFORM pg_notify('ab_tasks',jsonb_build_object('id',p_id)::text);
  RETURN jsonb_build_object('document',board_document_meta(d),'idempotent',false);
END $$
