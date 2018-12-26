/* pgl_ddl_deploy--1.4--1.5.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN include_everything
  BOOLEAN NOT NULL DEFAULT FALSE;

-- Now we have 3 configuration types
ALTER TABLE pgl_ddl_deploy.set_configs
  DROP CONSTRAINT repset_tables_or_regex_inclusion;

-- Only allow one of them to be chosen
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT single_configuration_type
  CHECK
  ((include_schema_regex IS NOT NULL
   AND NOT include_only_repset_tables)
   OR
   (include_only_repset_tables
    AND include_schema_regex IS NULL)
   OR
   (include_everything
    AND NOT include_only_repset_tables
    AND include_schema_regex IS NULL));

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT ddl_only_restrictions
  CHECK (NOT (ddl_only_replication AND include_only_repset_tables)); 

-- Need to adjust to after trigger and change function def 
DROP TRIGGER unique_tags ON pgl_ddl_deploy.set_configs;
DROP FUNCTION pgl_ddl_deploy.unique_tags();

-- We need to add the column include_everything to it in a nice order
DROP VIEW pgl_ddl_deploy.event_trigger_schema;

-- Support canceling or terminating blocking processes on subscriber
CREATE TYPE pgl_ddl_deploy.signals AS ENUM ('cancel','terminate');
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN signal_blocking_subscriber_sessions pgl_ddl_deploy.signals;
ALTER TABLE pgl_ddl_deploy.set_configs
  ADD COLUMN subscriber_lock_timeout INT;

ALTER TABLE pgl_ddl_deploy.set_configs
  ADD CONSTRAINT valid_signal_blocker_config
  CHECK
  (NOT (lock_safe_deployment AND (signal_blocking_subscriber_sessions IS NOT NULL OR subscriber_lock_timeout IS NOT NULL))
    AND NOT (subscriber_lock_timeout IS NOT NULL AND signal_blocking_subscriber_sessions IS NULL));

CREATE TABLE pgl_ddl_deploy.killed_blockers
(
  id           SERIAL PRIMARY KEY,
  signal       TEXT,
  successful   BOOLEAN,
  pid          INT,
  executed_at  TIMESTAMPTZ,
  usename      NAME,
  client_addr  INET,
  xact_start   TIMESTAMPTZ,
  state_change TIMESTAMPTZ,
  state        TEXT,
  query        TEXT,
  reported     BOOLEAN DEFAULT FALSE
);


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.unique_tags()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_output TEXT;
BEGIN
    WITH dupes AS (
    SELECT set_name,
        CASE
            WHEN include_only_repset_tables THEN 'include_only_repset_tables'
            WHEN include_everything AND NOT ddl_only_replication THEN 'include_everything'
            WHEN include_schema_regex IS NOT NULL AND NOT ddl_only_replication THEN 'include_schema_regex'
            WHEN ddl_only_replication THEN
                CASE
                    WHEN include_everything THEN 'ddl_only_include_everything'
                    WHEN include_schema_regex IS NOT NULL THEN 'ddl_only_include_schema_regex'
                END
        END AS category,
    unnest(array_cat(create_tags, drop_tags)) AS command_tag
    FROM pgl_ddl_deploy.set_configs
    GROUP BY 1, 2, 3
    HAVING COUNT(1) > 1)

    , aggregate_dupe_tags AS (
    SELECT set_name, category, string_agg(command_tag, ', ' ORDER BY command_tag) AS command_tags
    FROM dupes
    GROUP BY 1, 2
    )

    SELECT string_agg(format('%s: %s: %s', set_name, category, command_tags), ', ') AS output
    INTO v_output
    FROM aggregate_dupe_tags;

    IF v_output IS NOT NULL THEN
        RAISE EXCEPTION '%', format('You have overlapping configuration types and command tags which is not permitted: %s', v_output);
    END IF;
    RETURN NULL;
END;
$function$
;


CREATE TRIGGER unique_tags
AFTER INSERT OR UPDATE ON pgl_ddl_deploy.set_configs
FOR EACH ROW EXECUTE PROCEDURE pgl_ddl_deploy.unique_tags();


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.kill_blockers
(p_signal_blocking_subscriber_sessions pgl_ddl_deploy.signals,
p_nspname NAME,
p_relname NAME)
RETURNS TABLE (
signal       pgl_ddl_deploy.signals,
successful   BOOLEAN,
raised_message BOOLEAN,
pid          INT,
executed_at  TIMESTAMPTZ,
usename      NAME,
client_addr  INET,
xact_start   TIMESTAMPTZ,
state_change TIMESTAMPTZ,
state        TEXT,
query        TEXT,
reported     BOOLEAN
)
AS
$BODY$
BEGIN

RETURN QUERY
SELECT COALESCE(p_signal_blocking_subscriber_sessions,'cancel') AS signal,
  CASE
    WHEN p_signal_blocking_subscriber_sessions IS NULL
      THEN FALSE
    WHEN p_signal_blocking_subscriber_sessions = 'cancel'
      THEN pg_cancel_backend(l.pid)
    WHEN p_signal_blocking_subscriber_sessions = 'terminate'
      THEN pg_terminate_backend(l.pid)
  END AS successful,
  CASE
    WHEN p_signal_blocking_subscriber_sessions IS NULL
      THEN FALSE 
    WHEN p_signal_blocking_subscriber_sessions = 'cancel'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attemping cancel of blocking pid %s, query: %s', l.pid, a.query))
    WHEN p_signal_blocking_subscriber_sessions = 'terminate'
      THEN pgl_ddl_deploy.raise_message('WARNING', format('Attemping termination of blocking pid %s, query: %s', l.pid, a.query))
  END AS raised_message,
  l.pid,
  now() AS executed_at,
  a.usename,
  a.client_addr,
  a.xact_start,
  a.state_change,
  a.state,
  a.query,
  FALSE AS reported
FROM pg_locks l
INNER JOIN pg_class c on l.relation = c.oid
INNER JOIN pg_namespace n on c.relnamespace = n.oid
INNER JOIN pg_stat_activity a on l.pid = a.pid
WHERE NOT a.pid = pg_backend_pid()
-- both nspname and relname will be an empty string, thus a no-op, if for some reason one or the other
-- is not found on the provider side in pg_event_trigger_ddl_commands().  This is a safety mechanism!
AND n.nspname = p_nspname
AND c.relname = p_relname
AND a.datname = current_database()
AND c.relkind = 'r'
AND l.locktype = 'relation';

END;
$BODY$
SECURITY DEFINER
LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, NAME, NAME) FROM PUBLIC;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.add_role(p_roleoid oid)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
/******
Assuming roles doing DDL are not superusers, this function grants needed privileges
to run through the pgl_ddl_deploy DDL deployment.
This needs to be run on BOTH provider and subscriber.
******/
DECLARE
    v_rec RECORD;
    v_sql TEXT;
BEGIN

    FOR v_rec IN
        SELECT quote_ident(rolname) AS rolname FROM pg_roles WHERE oid = p_roleoid
    LOOP

    v_sql:='
    GRANT USAGE ON SCHEMA pglogical TO '||v_rec.rolname||';
    GRANT USAGE ON SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replicate_ddl_command(text, text[]) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pglogical.replication_set_add_table(name, regclass, boolean, text[], text) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.sql_command_tags(text) TO '||v_rec.rolname||';
    GRANT EXECUTE ON FUNCTION pgl_ddl_deploy.kill_blockers(pgl_ddl_deploy.signals, name, name) TO '||v_rec.rolname||';
    GRANT INSERT, UPDATE, SELECT ON ALL TABLES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgl_ddl_deploy TO '||v_rec.rolname||';
    GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO '||v_rec.rolname||';';

    EXECUTE v_sql;
    RETURN true;
    END LOOP;
RETURN false;
END;
$function$
;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.subscriber_command
(
  p_provider_name NAME,
  p_set_name TEXT[],
  p_nspname NAME,
  p_relname NAME,
  p_ddl_sql_sent TEXT,
  p_full_ddl TEXT,
  p_pid INT,
  p_set_config_id INT,
  p_queue_subscriber_failures BOOLEAN,
  p_signal_blocking_subscriber_sessions pgl_ddl_deploy.signals,
  p_lock_timeout INT,
-- This parameter currently only exists to make testing this function easier
  p_run_anywhere BOOLEAN = FALSE
)
RETURNS BOOLEAN
AS $pgl_ddl_deploy_sql$
DECLARE
  v_succeeded BOOLEAN;
  v_error_message TEXT;
BEGIN

--Only run on subscriber with this replication set, and matching provider node name
IF EXISTS (SELECT 1
              FROM pglogical.subscription s
              INNER JOIN pglogical.node n
                ON n.node_id = s.sub_origin
                AND n.node_name = p_provider_name
              WHERE sub_replication_sets && p_set_name) OR p_run_anywhere THEN

    v_error_message = NULL;
    WHILE TRUE LOOP
    IF p_signal_blocking_subscriber_sessions IS NOT NULL THEN
    -- We cannot RESET LOCAL lock_timeout but that should not be necessary because it will end with the transaction
      EXECUTE format('SET LOCAL lock_timeout TO %s', p_lock_timeout);
    END IF;
    BEGIN

     --Execute DDL
     RAISE LOG 'pgl_ddl_deploy attempting execution: %', p_full_ddl;
     
    --Execute DDL - the reason we use execute here is partly to handle no trailing semicolon
     EXECUTE p_full_ddl;

     v_succeeded = TRUE;
     EXIT;

    EXCEPTION
      WHEN lock_not_available THEN
        IF p_signal_blocking_subscriber_sessions IS NOT NULL THEN
          INSERT INTO pgl_ddl_deploy.killed_blockers
            (signal,
            successful,
            pid,
            executed_at,
            usename,
            client_addr,
            xact_start,
            state_change,
            state,
            query,
            reported)
          SELECT
            signal,
            successful,
            pid,
            executed_at,
            usename,
            client_addr,
            xact_start,
            state_change,
            state,
            query,
            reported
          FROM pgl_ddl_deploy.kill_blockers(
            p_signal_blocking_subscriber_sessions,
            p_nspname,
            p_relname
          );

          -- Continue and retry again but allow a brief pause
          PERFORM pg_sleep(3);
        ELSE
          -- If p_signal_blocking_subscriber_sessions is not configured but we hit a lock_timeout,
          -- then the replication user or cluster is configured with a global lock_timeout.  Raise in this case.
          RAISE;
        END IF;
      WHEN OTHERS THEN
        IF p_queue_subscriber_failures THEN
          RAISE WARNING 'Subscriber DDL failed with errors (see pgl_ddl_deploy.subscriber_logs): %', SQLERRM;
          v_succeeded = FALSE;
          v_error_message = SQLERRM;
          EXIT;
        ELSE
          RAISE;
        END IF;
    END;
    END LOOP;

    INSERT INTO pgl_ddl_deploy.subscriber_logs
    (set_name,
     provider_pid,
     provider_node_name,
     provider_set_config_id,
     executed_as_role,
     subscriber_pid,
     executed_at,
     ddl_sql,
     full_ddl_sql,
     succeeded,
     error_message)
    VALUES
    (p_set_name,
     p_pid,
     p_provider_name,
     p_set_config_id,
     current_role,
     pg_backend_pid(),
     current_timestamp,
     p_ddl_sql_sent,
     p_full_ddl,
     v_succeeded,
     v_error_message);

END IF;

RETURN v_succeeded;

END;
$pgl_ddl_deploy_sql$
LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION pgl_ddl_deploy.raise_message
(p_log_level TEXT,
p_message TEXT)
RETURNS BOOLEAN 
AS $BODY$
BEGIN

EXECUTE format($$
DO $block$
BEGIN
RAISE %s $pgl_ddl_deploy_msg$%s$pgl_ddl_deploy_msg$;
END$block$;
$$, p_log_level, p_message);
RETURN TRUE;

END;
$BODY$
LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE VIEW pgl_ddl_deploy.event_trigger_schema AS
WITH vars AS
(SELECT
  id,
   set_name,
  'pgl_ddl_deploy.auto_rep_ddl_create_'||id::TEXT||'_'||set_name AS auto_replication_create_function_name,
  'pgl_ddl_deploy.auto_rep_ddl_drop_'||id::TEXT||'_'||set_name AS auto_replication_drop_function_name,
  'pgl_ddl_deploy.auto_rep_ddl_unsupp_'||id::TEXT||'_'||set_name AS auto_replication_unsupported_function_name,
  'auto_rep_ddl_create_'||id::TEXT||'_'||set_name AS auto_replication_create_trigger_name,
  'auto_rep_ddl_drop_'||id::TEXT||'_'||set_name AS auto_replication_drop_trigger_name,
  'auto_rep_ddl_unsupp_'||id::TEXT||'_'||set_name AS auto_replication_unsupported_trigger_name,
  include_schema_regex,
  include_only_repset_tables,
  create_tags,
  drop_tags,
  ddl_only_replication,
  include_everything,
  signal_blocking_subscriber_sessions,
  subscriber_lock_timeout,

  /****
  These constants in DECLARE portion of all functions is identical and can be shared
   */
  $BUILD$
  c_search_path TEXT = (SELECT current_setting('search_path'));
  c_provider_name TEXT;
   --TODO: How do I decide which replication set we care about?
  v_pid INT = pg_backend_pid();
  v_rec RECORD;
  v_ddl_sql_raw TEXT;
  v_ddl_sql_sent TEXT;
  v_full_ddl TEXT;
  v_sql_tags TEXT[];
  v_cmd_rec RECORD;
  v_subcmd_rec RECORD;
  v_excluded_subcommands TEXT;
  v_contains_any_valid_subcommand INT;

  /*****
  We need to strip the DDL of:
    1. Transaction begin and commit, which cannot run inside plpgsql
  *****/
  v_ddl_strip_regex TEXT = '(begin\W*transaction\W*|begin\W*work\W*|begin\W*|commit\W*transaction\W*|commit\W*work\W*|commit\W*);';
  v_txid BIGINT;
  v_ddl_length INT;
  v_sql TEXT;
  v_cmd_count INT;
  v_match_count INT;
  v_exclude_always_match_count INT;
  v_nspname TEXT;
  v_relname TEXT;
  v_error TEXT;
  v_error_detail TEXT;
  v_context TEXT;
  v_excluded_count INT;
  c_exclude_always TEXT = pgl_ddl_deploy.exclude_regex();
  c_exception_msg TEXT = 'Deployment exception logged in pgl_ddl_deploy.exceptions';

  --Configurable options in function setup
  c_set_config_id INT = $BUILD$||id::TEXT||$BUILD$;
  -- Even though pglogical supports an array of sets, we only pipe DDL through one at a time
  -- So c_set_name is a text not text[] data type.
  c_set_name TEXT = '$BUILD$||set_name||$BUILD$';
  c_include_schema_regex TEXT = $BUILD$||COALESCE(''''||include_schema_regex||'''','NULL')||$BUILD$;
  c_lock_safe_deployment BOOLEAN = $BUILD$||lock_safe_deployment||$BUILD$;
  c_allow_multi_statements BOOLEAN = $BUILD$||allow_multi_statements||$BUILD$;
  c_include_only_repset_tables BOOLEAN = $BUILD$||include_only_repset_tables||$BUILD$;
  c_include_everything BOOLEAN = $BUILD$||include_everything||$BUILD$;
  c_queue_subscriber_failures BOOLEAN = $BUILD$||queue_subscriber_failures||$BUILD$;
  c_blacklisted_tags TEXT[] = '$BUILD$||blacklisted_tags::TEXT||$BUILD$';
  c_exclude_alter_table_subcommands TEXT[] = $BUILD$||COALESCE(quote_literal(exclude_alter_table_subcommands::TEXT),'NULL')||$BUILD$;
  c_signal_blocking_subscriber_sessions TEXT = $BUILD$||COALESCE(quote_literal(signal_blocking_subscriber_sessions::TEXT),'NULL')||$BUILD$;
  c_subscriber_lock_timeout INT = $BUILD$||COALESCE(subscriber_lock_timeout::TEXT,'NULL')||$BUILD$;

    --Constants based on configuration
  c_exec_prefix TEXT =(CASE
                          WHEN c_lock_safe_deployment
                          THEN 'SELECT pgl_ddl_deploy.lock_safe_executor($PGL_DDL_DEPLOY$'
                          ELSE ''
                        END);
  c_exec_suffix TEXT = (CASE
                          WHEN c_lock_safe_deployment
                          THEN '$PGL_DDL_DEPLOY$);'
                          ELSE ''
                        END);
  $BUILD$::TEXT AS declare_constants,

  $BUILD$
  --If there are any matches to our replication config, get the query
  --This will either be sent, or logged at this point if not deployable
  IF (c_include_everything AND v_exclude_always_match_count = 0) OR v_match_count > 0 THEN
        v_ddl_sql_raw = current_query();
        v_txid = txid_current();
  END IF;
  $BUILD$::TEXT AS shared_get_query,
/****
  This is the portion of the event trigger function that evaluates if SQL
  is appropriate to propagate, and does propagate the event.  It is shared
  between the normal and drop event trigger functions.
   */
  $BUILD$
        /****
          A multi-statement SQL command may fire this event trigger more than once
          This check ensures the SQL is propagated only once, if at all
         */
        IF EXISTS
           (SELECT 1 FROM pgl_ddl_deploy.events
            WHERE set_name = c_set_name
              AND txid = v_txid
              AND ddl_sql_raw = v_ddl_sql_raw
              AND pid = v_pid)
           OR EXISTS
           (SELECT 1 FROM pgl_ddl_deploy.unhandled
            WHERE set_name = c_set_name
              AND txid = v_txid
              AND ddl_sql_raw = v_ddl_sql_raw
              AND pid = v_pid)
            THEN
          RETURN;
        END IF;

        /****
          Get the command tags and reject blacklisted tags
         */
        v_sql_tags:=(SELECT pgl_ddl_deploy.sql_command_tags(v_ddl_sql_raw));
        IF (SELECT c_blacklisted_tags && v_sql_tags) THEN
          PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_config_id,
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'rejected_command_tags',
               v_txid);
          RETURN;
        /****
          If we are not allowing multi-statements at all, reject
         */
        ELSEIF (SELECT ARRAY[TG_TAG]::TEXT[] <> v_sql_tags WHERE NOT c_allow_multi_statements) THEN
          PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_config_id,
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'rejected_multi_statement',
               v_txid);
          RETURN;
        END IF;

        /****
          If this is an ALTER TABLE statement and we are excluding any subcommand tags, process now.
          Note the following.

          Because there can be more than one subcommand, we have a limited ability
          to filter out subcommands until such a time as we may have a mechanism for rebuilding only
          the SQL we want.  In other words, if we have one subcommand that we DO want (i.e. ADD COLUMN)
          and one we don't want (i.e. REFERENCES) in the same SQL, and we are "excluding" the latter,
          we can't do that exclusion safely because we WANT the ADD COLUMN statement.  In such a case,
          we are still going to allow the DDL to go through because it's better to break replication than
          miss a column addition.

          But if the only subcommand is an excluded one, i.e. ADD CONSTRAINT, then we will indeed ignore
          the DDL and the function will RETURN without executing replicate_ddl_command.
        */
        IF TG_TAG = 'ALTER TABLE' AND c_exclude_alter_table_subcommands IS NOT NULL THEN
          FOR v_cmd_rec IN
            SELECT * FROM pg_event_trigger_ddl_commands()
          LOOP
            IF pgl_ddl_deploy.get_command_type(v_cmd_rec.command) = 'alter table' THEN
              WITH subcommands AS (
                SELECT subcommand,
                  c_exclude_alter_table_subcommands && ARRAY[subcommand] AS subcommand_is_excluded,
                  MAX(CASE WHEN c_exclude_alter_table_subcommands && ARRAY[subcommand] THEN 0 ELSE 1 END) OVER() AS contains_any_valid_subcommand
                FROM unnest(pgl_ddl_deploy.get_altertable_subcmdtypes(v_cmd_rec.command)) AS subcommand
              )

              SELECT (SELECT string_agg(subcommand,', ') FROM subcommands WHERE subcommand_is_excluded),
                (SELECT contains_any_valid_subcommand FROM subcommands LIMIT 1)
               INTO v_excluded_subcommands,
                v_contains_any_valid_subcommand;
              IF v_excluded_subcommands IS NOT NULL AND v_contains_any_valid_subcommand = 0 THEN
                RAISE LOG 'Not processing DDL due to excluded subcommand(s): %: %', v_excluded_subcommands, v_ddl_sql_raw;
                RETURN;
              ELSEIF v_excluded_subcommands IS NOT NULL AND v_contains_any_valid_subcommand = 1 THEN
                RAISE WARNING $INNER_BLOCK$Filtering out more than one subcommand in one ALTER TABLE is not supported.
                Allowing to proceed: Rejected: %, SQL: %$INNER_BLOCK$, v_excluded_subcommands, v_ddl_sql_raw;
              END IF;
            END IF;
          END LOOP;
        END IF;

        v_ddl_sql_sent = v_ddl_sql_raw;

        --If there are BEGIN/COMMIT tags, attempt to strip and reparse
        IF (SELECT ARRAY['BEGIN','COMMIT']::TEXT[] && v_sql_tags) THEN
          v_ddl_sql_sent = regexp_replace(v_ddl_sql_sent, v_ddl_strip_regex, '', 'ig');

          --Sanity reparse
          PERFORM pgl_ddl_deploy.sql_command_tags(v_ddl_sql_sent);
        END IF;

        --Get provider name, in order only to run command on a subscriber to this provider
        c_provider_name:=(SELECT n.node_name FROM pglogical.node n INNER JOIN pglogical.local_node ln USING (node_id));

        /*
          Build replication DDL command which will conditionally run only on the subscriber
          In other words, this MUST be a no-op on the provider
          **Because the DDL has already run at this point (ddl_command_end)**
        */
        v_full_ddl:=$INNER_BLOCK$
        --Be sure to use provider's search_path for SQL environment consistency
            SET SEARCH_PATH TO $INNER_BLOCK$||
            CASE WHEN COALESCE(c_search_path,'') IN('','""') THEN quote_literal('') ELSE c_search_path END||$INNER_BLOCK$;

            $INNER_BLOCK$||c_exec_prefix||v_ddl_sql_sent||c_exec_suffix||$INNER_BLOCK$
            ;
        $INNER_BLOCK$;

        v_sql:=$INNER_BLOCK$
        SELECT pglogical.replicate_ddl_command($REPLICATE_DDL_COMMAND$
        SELECT pgl_ddl_deploy.subscriber_command
        (
          p_provider_name := $INNER_BLOCK$||quote_literal(c_provider_name)||$INNER_BLOCK$,
          p_set_name := ARRAY[$INNER_BLOCK$||quote_literal(c_set_name)||$INNER_BLOCK$],
          p_nspname := $INNER_BLOCK$||COALESCE(quote_literal(v_nspname), 'NULL')::TEXT||$INNER_BLOCK$,
          p_relname := $INNER_BLOCK$||COALESCE(quote_literal(v_relname), 'NULL')::TEXT||$INNER_BLOCK$,
          p_ddl_sql_sent := $pgl_ddl_deploy_sql$$INNER_BLOCK$||v_ddl_sql_sent||$INNER_BLOCK$$pgl_ddl_deploy_sql$,
          p_full_ddl := $pgl_ddl_deploy_sql$$INNER_BLOCK$||v_full_ddl||$INNER_BLOCK$$pgl_ddl_deploy_sql$,
          p_pid := $INNER_BLOCK$||v_pid::TEXT||$INNER_BLOCK$,
          p_set_config_id := $INNER_BLOCK$||c_set_config_id::TEXT||$INNER_BLOCK$,
          p_queue_subscriber_failures := $INNER_BLOCK$||c_queue_subscriber_failures||$INNER_BLOCK$,
          p_signal_blocking_subscriber_sessions := $INNER_BLOCK$||COALESCE(quote_literal(c_signal_blocking_subscriber_sessions),'NULL')||$INNER_BLOCK$,
          p_lock_timeout := $INNER_BLOCK$||COALESCE(c_subscriber_lock_timeout, 3000)||$INNER_BLOCK$
        );
        $REPLICATE_DDL_COMMAND$,
        --Pipe this DDL command through chosen replication set
        ARRAY['$INNER_BLOCK$||c_set_name||$INNER_BLOCK$']);
        $INNER_BLOCK$;
        
        RAISE DEBUG '%', v_sql;
        EXECUTE v_sql;

        INSERT INTO pgl_ddl_deploy.events
        (set_config_id,
         set_name,
         pid,
         executed_at,
         ddl_sql_raw,
         ddl_sql_sent,
         txid)
        VALUES
        (c_set_config_id,
         c_set_name,
         v_pid,
         current_timestamp,
         v_ddl_sql_raw,
         v_ddl_sql_sent,
         v_txid);
  $BUILD$::TEXT AS shared_deploy_logic,
  $BUILD$
  ELSEIF (v_match_count > 0 AND v_cmd_count <> v_match_count) THEN
    PERFORM pgl_ddl_deploy.log_unhandled(
     c_set_config_id,
     c_set_name,
     v_pid,
     v_ddl_sql_raw,
     TG_TAG,
     'mixed_objects',
     v_txid);
  $BUILD$::TEXT AS shared_mixed_obj_logic,

  $BUILD$
  /**
    Catch any exceptions and log in a local table
    As a safeguard, if even the exception handler fails, exit cleanly but add a server log message
  **/
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_context = PG_EXCEPTION_CONTEXT, v_error = MESSAGE_TEXT, v_error_detail = PG_EXCEPTION_DETAIL;
    BEGIN
      INSERT INTO pgl_ddl_deploy.exceptions (set_config_id, set_name, pid, executed_at, ddl_sql, err_msg, err_state)
      VALUES (c_set_config_id, c_set_name, v_pid, current_timestamp, v_sql, v_error||v_context, SQLSTATE);
      RAISE WARNING '%', c_exception_msg;
    --No matter what, don't let this function block any DDL
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Unhandled exception % %', SQLERRM, SQLSTATE;
    END;
  $BUILD$::TEXT AS shared_exception_handler,

  $BUILD$
  FROM pg_namespace n
  INNER JOIN pg_class c ON n.oid = c.relnamespace
    AND c.relpersistence = 'p'
  WHERE n.nspname ~* c_include_schema_regex
    AND n.nspname !~* c_exclude_always
    AND EXISTS (SELECT 1
    FROM pg_index i
    WHERE i.indrelid = c.oid
      AND i.indisprimary)
    AND NOT EXISTS
    (SELECT 1
    FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
    INNER JOIN pglogical.replication_set r
      ON r.set_id = rsr.set_id
    WHERE r.set_name = c_set_name
      AND rsr.set_reloid = c.oid)
  $BUILD$::TEXT AS shared_repl_set_tables,

  $BUILD$
      SUM(CASE
          WHEN
          --include_schema_regex usage:
            (
              (NOT $BUILD$||include_only_repset_tables||$BUILD$) AND
              (
                (schema_name ~* c_include_schema_regex
                AND schema_name !~* c_exclude_always)
                OR
                (object_type = 'schema'
                AND object_identity ~* c_include_schema_regex
                AND object_identity !~* c_exclude_always)
              )
            )
            OR
          --include_only_repset_tables usage:
            (
              ($BUILD$||include_only_repset_tables||$BUILD$) AND
              (EXISTS
                (
                SELECT 1
                FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
                INNER JOIN pglogical.replication_set rs USING (set_id)
                WHERE rsr.set_reloid = c.objid
                  AND c.object_type in('table','table column','table constraint')
                  AND rs.set_name = '$BUILD$||set_name||$BUILD$'
                )
              )
            )
            THEN 1
          ELSE 0 END) AS match_count,
      SUM(CASE
          WHEN
          --include_everything usage still excludes exclude_always regex:
            (
              ($BUILD$||include_everything||$BUILD$) AND
              (
                (schema_name ~* c_exclude_always)
                OR
                (object_type = 'schema'
                AND object_identity ~* c_exclude_always)
              )
            )
            THEN 1
          ELSE 0 END) AS exclude_always_match_count
  $BUILD$::TEXT AS shared_match_count
FROM pglogical.replication_set rs
INNER JOIN pgl_ddl_deploy.set_configs sc USING (set_name)
)

, build AS (
SELECT
  id,
  set_name,
  include_schema_regex,
  include_only_repset_tables,
  include_everything,
  signal_blocking_subscriber_sessions,
  subscriber_lock_timeout,
  auto_replication_create_function_name,
  auto_replication_drop_function_name,
  auto_replication_unsupported_function_name,
  auto_replication_create_trigger_name,
  auto_replication_drop_trigger_name,
  auto_replication_unsupported_trigger_name,

CASE WHEN create_tags IS NULL THEN '--no-op-null-create-tags'::TEXT ELSE
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$ || auto_replication_create_function_name || $BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

  /*****
  Only enter execution body if object being altered is relevant
   */
  SELECT COUNT(1)
    , $BUILD$||shared_match_count||$BUILD$
    , MAX(c.schema_name)
    , MAX(cl.relname)
    INTO v_cmd_count, v_match_count, v_exclude_always_match_count, v_nspname, v_relname
  FROM pg_event_trigger_ddl_commands() c
  LEFT JOIN LATERAL
    (SELECT cl.relname
     FROM pg_class cl
     WHERE cl.oid = c.objid
       AND c.classid = (SELECT oid FROM pg_class WHERE relname = 'pg_class')
    -- There should only be one table modified per event trigger
    -- At least that's the best we will do now
     LIMIT 1) cl ON TRUE;

      $BUILD$||shared_get_query||$BUILD$

  IF ((c_include_everything AND v_exclude_always_match_count = 0) OR (v_match_count > 0 AND v_cmd_count = v_match_count))
      THEN

        $BUILD$||shared_deploy_logic||$BUILD$

        INSERT INTO pgl_ddl_deploy.commands
            (set_config_id,
            set_name,
            pid,
            txid,
            classid,
            objid,
            objsubid,
            command_tag,
            object_type,
            schema_name,
            object_identity,
            in_extension)
        SELECT c_set_config_id,
            c_set_name,
            v_pid,
            v_txid,
            classid,
            objid,
            objsubid,
            command_tag,
            object_type,
            schema_name,
            object_identity,
            in_extension
        FROM pg_event_trigger_ddl_commands();

        /**
          Add table to replication set immediately, if required.
          We do not filter to tags here, because of possibility of multi-statement SQL.
          Optional ddl_only_replication will never auto-add tables to replication because the
          purpose is to only replicate keep the structure synchronized on the subscriber with no data.
        **/
        IF NOT $BUILD$||include_only_repset_tables||$BUILD$ AND NOT $BUILD$||ddl_only_replication||$BUILD$ THEN
          PERFORM pglogical.replication_set_add_table(
            set_name:=c_set_name
            ,relation:=c.oid
            ,synchronize_data:=false
          )
          $BUILD$||shared_repl_set_tables||$BUILD$;
        END IF;

  $BUILD$||shared_mixed_obj_logic||$BUILD$

  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$::TEXT
END  AS auto_replication_function,

CASE WHEN drop_tags IS NULL THEN '--no-op-null-drop-tags'::TEXT ELSE
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_drop_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

  /*****
  Only enter execution body if object being altered is relevant
   */
  SELECT COUNT(1)
    , $BUILD$||shared_match_count||$BUILD$
    , SUM(CASE
          WHEN
          --include_schema_regex usage:
            (
              (NOT $BUILD$||include_only_repset_tables||$BUILD$) AND
              (
                (schema_name !~* '^(pg_catalog|pg_toast)$'
                AND schema_name !~* c_include_schema_regex)
                OR (object_type = 'schema'
                AND object_identity !~* '^(pg_catalog|pg_toast)$'
                AND object_identity !~* c_include_schema_regex)
              )
            )
          --include_only_repset_tables cannot be used with DROP because
          --the objects no longer exist to be checked:
            THEN 1
          ELSE 0 END) AS excluded_count
    INTO v_cmd_count, v_match_count, v_exclude_always_match_count, v_excluded_count
  FROM pg_event_trigger_dropped_objects() c;

  $BUILD$||shared_get_query||$BUILD$

  IF ((c_include_everything AND v_exclude_always_match_count = 0) OR (v_match_count > 0 AND v_excluded_count = 0))

      THEN

        $BUILD$||shared_deploy_logic||$BUILD$

        INSERT INTO pgl_ddl_deploy.commands
            (set_config_id,
            set_name,
            pid,
            txid,
            classid,
            objid,
            objsubid,
            command_tag,
            object_type,
            schema_name,
            object_identity,
            in_extension)
        SELECT c_set_config_id,
            c_set_name,
            v_pid,
            v_txid,
            classid,
            objid,
            objsubid,
            TG_TAG,
            object_type,
            schema_name,
            object_identity,
            NULL
        FROM pg_event_trigger_dropped_objects();

  $BUILD$||shared_mixed_obj_logic||$BUILD$

  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
END
  AS auto_replication_drop_function,

CASE WHEN include_only_repset_tables THEN '--no-op-only-repset-tables'::TEXT ELSE
$BUILD$
CREATE OR REPLACE FUNCTION $BUILD$||auto_replication_unsupported_function_name||$BUILD$() RETURNS EVENT_TRIGGER
AS
$BODY$
DECLARE
  $BUILD$||declare_constants||$BUILD$
BEGIN

 /*****
  Only enter execution body if object being altered is relevant
   */
  SELECT COUNT(1)
    , $BUILD$||shared_match_count||$BUILD$
    INTO v_cmd_count, v_match_count, v_exclude_always_match_count
  FROM pg_event_trigger_ddl_commands() c;

  IF ((c_include_everything AND v_exclude_always_match_count = 0) OR v_match_count > 0)
    THEN

    v_ddl_sql_raw = current_query();

    PERFORM pgl_ddl_deploy.log_unhandled(
               c_set_config_id,
               c_set_name,
               v_pid,
               v_ddl_sql_raw,
               TG_TAG,
               'unsupported_command',
               v_txid);
  END IF;

$BUILD$||shared_exception_handler||$BUILD$
END;
$BODY$
LANGUAGE plpgsql;
$BUILD$
END
  AS auto_replication_unsupported_function,

CASE WHEN create_tags IS NULL THEN '--no-op-null-create-tags'::TEXT ELSE
$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_create_trigger_name||$BUILD$ ON ddl_command_end
WHEN TAG IN('$BUILD$||array_to_string(create_tags,$$','$$)||$BUILD$')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$ || auto_replication_create_function_name || $BUILD$();
$BUILD$::TEXT
END AS auto_replication_trigger,

CASE WHEN drop_tags IS NULL THEN '--no-op-null-drop-tags'::TEXT ELSE
$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ ON sql_drop
WHEN TAG IN('$BUILD$||array_to_string(drop_tags,$$','$$)||$BUILD$')
--TODO - CREATE INDEX HANDLING
EXECUTE PROCEDURE $BUILD$||auto_replication_drop_function_name||$BUILD$();
$BUILD$::TEXT
END AS auto_replication_drop_trigger,

CASE WHEN include_only_repset_tables THEN '--no-op-only-repset-tables'::TEXT ELSE
$BUILD$
CREATE EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ ON ddl_command_end
WHEN TAG IN('$BUILD$||array_to_string(pgl_ddl_deploy.unsupported_tags(),$$','$$)||$BUILD$')
EXECUTE PROCEDURE $BUILD$||auto_replication_unsupported_function_name||$BUILD$();
$BUILD$::TEXT
END AS auto_replication_unsupported_trigger,

$BUILD$
DROP TABLE IF EXISTS tmp_objs;
CREATE TEMP TABLE tmp_objs (obj_type, obj_name) AS (
VALUES
('EVENT TRIGGER','$BUILD$||auto_replication_create_trigger_name||$BUILD$'),
('EVENT TRIGGER','$BUILD$||auto_replication_drop_trigger_name||$BUILD$'),
('EVENT TRIGGER','$BUILD$||auto_replication_unsupported_trigger_name||$BUILD$'),
('FUNCTION','$BUILD$||auto_replication_create_function_name||$BUILD$()'),
('FUNCTION','$BUILD$||auto_replication_drop_function_name||$BUILD$()'),
('FUNCTION','$BUILD$||auto_replication_unsupported_function_name||$BUILD$()')
);

SELECT pgl_ddl_deploy.drop_ext_object(obj_type, obj_name)
FROM tmp_objs;
DROP EVENT TRIGGER IF EXISTS $BUILD$||auto_replication_create_trigger_name||', '||auto_replication_drop_trigger_name||', '||auto_replication_unsupported_trigger_name||$BUILD$;
DROP FUNCTION IF EXISTS $BUILD$||auto_replication_create_function_name||$BUILD$();
DROP FUNCTION IF EXISTS $BUILD$||auto_replication_drop_function_name||$BUILD$();
DROP FUNCTION IF EXISTS $BUILD$||auto_replication_unsupported_function_name||$BUILD$();
$BUILD$
    AS undeploy_sql
FROM vars)

SELECT
  b.id,
  b.set_name,
  b.include_schema_regex,
  b.include_only_repset_tables,
  b.include_everything,
  b.signal_blocking_subscriber_sessions,
  b.subscriber_lock_timeout,
  b.auto_replication_create_function_name,
  b.auto_replication_drop_function_name,
  b.auto_replication_unsupported_function_name,
  b.auto_replication_create_trigger_name,
  b.auto_replication_drop_trigger_name,
  b.auto_replication_unsupported_trigger_name,
  b.auto_replication_function,
  b.auto_replication_drop_function,
  b.auto_replication_unsupported_function,
  b.auto_replication_trigger,
  b.auto_replication_drop_trigger,
  b.auto_replication_unsupported_trigger,
  b.undeploy_sql,
  b.undeploy_sql||
  auto_replication_function||$BUILD$
  $BUILD$||auto_replication_drop_function||$BUILD$
  $BUILD$||auto_replication_unsupported_function||$BUILD$
  $BUILD$||auto_replication_trigger||$BUILD$
  $BUILD$||auto_replication_drop_trigger||$BUILD$
  $BUILD$||auto_replication_unsupported_trigger||$BUILD$
  SELECT pgl_ddl_deploy.add_ext_object(obj_type, obj_name)
  FROM tmp_objs;
  $BUILD$ AS deploy_sql,
  $BUILD$
  ALTER EVENT TRIGGER $BUILD$||auto_replication_create_trigger_name||$BUILD$ DISABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ DISABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ DISABLE;
  $BUILD$ AS disable_sql,
  $BUILD$
  ALTER EVENT TRIGGER $BUILD$||auto_replication_create_trigger_name||$BUILD$ ENABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_drop_trigger_name||$BUILD$ ENABLE;
  ALTER EVENT TRIGGER $BUILD$||auto_replication_unsupported_trigger_name||$BUILD$ ENABLE;
  $BUILD$ AS enable_sql,
  EXISTS (SELECT 1
    FROM pg_event_trigger
    WHERE evtname IN(
        auto_replication_create_trigger_name,
        auto_replication_drop_trigger_name,
        auto_replication_unsupported_trigger_name
        )
        AND evtenabled IN('O','R','A')
    ) AS is_deployed
FROM build b;


