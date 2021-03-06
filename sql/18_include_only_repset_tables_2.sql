SET client_min_messages = warning;

SELECT pglogical.replication_set_add_table(
  set_name:='my_special_tables_1'
  ,relation:='special.foo'::REGCLASS);

SELECT pglogical.replication_set_add_table(
  set_name:='my_special_tables_2'
  ,relation:='special.bar'::REGCLASS);

--Deploy by set_name
SELECT pgl_ddl_deploy.deploy('my_special_tables_1');
SELECT pgl_ddl_deploy.deploy('my_special_tables_2');

--Ensure these kinds of configs only have 'create' event triggers
SELECT COUNT(1)
FROM pg_event_trigger evt
INNER JOIN pgl_ddl_deploy.event_trigger_schema ets
    ON evt.evtname IN(auto_replication_unsupported_trigger_name,
    ets.auto_replication_drop_trigger_name,
    ets.auto_replication_create_trigger_name)
WHERE include_only_repset_tables;

--Deploy by id
SELECT pgl_ddl_deploy.deploy(id)
FROM pgl_ddl_deploy.set_configs
WHERE set_name = 'my_special_tables_1';

SELECT pgl_ddl_deploy.deploy(id)
FROM pgl_ddl_deploy.set_configs
WHERE set_name = 'my_special_tables_2';
