CREATE FUNCTION board_notify() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE row_data jsonb; topic text; entity_id text;
BEGIN
  row_data:=to_jsonb(NEW);
  topic:=CASE TG_TABLE_NAME WHEN 'task_events' THEN 'ab_tasks' ELSE 'ab_'||TG_TABLE_NAME END;
  entity_id:=CASE TG_TABLE_NAME WHEN 'task_events' THEN row_data->>'task_id' ELSE row_data->>'id' END;
  PERFORM pg_notify(topic,jsonb_build_object('id',entity_id,'revision',coalesce(row_data->'revision',row_data->'new_revision'))::text);
  RETURN NEW;
END $$
-- statement-break
CREATE TRIGGER agents_notify AFTER INSERT OR UPDATE ON agents FOR EACH ROW EXECUTE FUNCTION board_notify()
-- statement-break
CREATE TRIGGER tasks_notify AFTER INSERT OR UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION board_notify()
-- statement-break
CREATE TRIGGER task_events_notify AFTER INSERT ON task_events FOR EACH ROW EXECUTE FUNCTION board_notify()
-- statement-break
CREATE TRIGGER messages_notify AFTER INSERT OR UPDATE ON messages FOR EACH ROW EXECUTE FUNCTION board_notify()
