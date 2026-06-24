-- ===========================================================================
-- Standing pg_cron jobs. Seconds intervals need pg_cron >= 1.5.
-- `select * from cron.job` is the live schedule list. Per-pipeline jobs
-- (pipeline-<slug>) are added on demand by schedule_pipeline().
-- ===========================================================================

SELECT cron.schedule('almanac-poll',    '5 seconds', 'SELECT tg_poll()');
SELECT cron.schedule('almanac-process', '5 seconds', 'SELECT process_pending()');
SELECT cron.schedule('almanac-kb',      '* * * * *', 'SELECT kb_ingest()');  -- every minute
SELECT cron.schedule('almanac-code',    '20 seconds', 'SELECT code_poll()');     -- watch coding jobs
SELECT cron.schedule('almanac-remind',  '* * * * *', 'SELECT reminder_tick()');  -- one-off reminders
SELECT cron.schedule('almanac-daily',   '0 7 * * *', 'SELECT daily_summary()');

-- job_run_details grows fast at seconds granularity; keep it trimmed.
SELECT cron.schedule('almanac-cleanup', '0 3 * * *', $$
  DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days';
  DELETE FROM messages WHERE status = 'done' AND created_at < now() - interval '90 days';
  DELETE FROM pipeline_runs WHERE finished_at IS NOT NULL AND finished_at < now() - interval '30 days';
$$);
