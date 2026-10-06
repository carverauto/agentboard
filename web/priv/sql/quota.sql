CREATE FUNCTION board_quota(p_data jsonb,p_digest text,p_actor text,p_model text,p_harness text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE report_id bigint; observation_id bigint; provider jsonb; item jsonb; existing quota_reports%ROWTYPE;
BEGIN
  PERFORM board_actor(p_actor,p_model,p_harness);
  INSERT INTO quota_reports(source_agent_id,model,harness,schema_version,digest,generated_at,raw)
    VALUES(p_actor,p_model,p_harness,(p_data->'raw'->>'schemaVersion')::integer,p_digest,
      (p_data->'raw'->>'generatedAt')::timestamptz,p_data->'raw')
    ON CONFLICT(source_agent_id,digest) DO NOTHING RETURNING id INTO report_id;
  IF report_id IS NULL THEN
    SELECT * INTO existing FROM quota_reports WHERE source_agent_id=p_actor AND digest=p_digest;
    RETURN jsonb_build_object('report',to_jsonb(existing)-'raw','idempotent',true);
  END IF;
  FOR provider IN SELECT jsonb_array_elements(p_data->'providers') LOOP
    INSERT INTO quota_observations(report_id,provider,account_key,provider_data)
      VALUES(report_id,provider->>'provider',provider->>'account_key',provider) RETURNING id INTO observation_id;
    FOR item IN SELECT jsonb_array_elements(provider->'windows') LOOP
      INSERT INTO quota_windows(observation_id,window_id,data) VALUES(observation_id,item->>'id',item);
    END LOOP;
    FOR item IN SELECT jsonb_array_elements(coalesce(provider->'quota_semantics'->'effective_availability','[]')) LOOP
      INSERT INTO quota_scopes(observation_id,scope,data) VALUES(observation_id,item->>'scope',item);
    END LOOP;
  END LOOP;
  PERFORM pg_notify('ab_quota',jsonb_build_object('id',report_id)::text);
  SELECT * INTO existing FROM quota_reports WHERE id=report_id;
  RETURN jsonb_build_object('report',to_jsonb(existing)-'raw','idempotent',false);
END $$
