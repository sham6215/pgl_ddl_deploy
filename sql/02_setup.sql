SELECT pglogical.create_node('test','host=localhost') INTO TEMP foonode;
DROP TABLE foonode;

WITH sets AS (
SELECT 'test'||generate_series AS set_name
FROM generate_series(1,8)
)

SELECT pglogical.create_replication_set
(set_name:=s.set_name
,replicate_insert:=TRUE
,replicate_update:=TRUE
,replicate_delete:=TRUE
,replicate_truncate:=TRUE) AS result
INTO TEMP repsets
FROM sets s
WHERE NOT EXISTS (
SELECT 1
FROM pglogical.replication_set
WHERE set_name = s.set_name);

DROP TABLE repsets;
CREATE ROLE test_pgl_ddl_deploy LOGIN;
GRANT CREATE ON DATABASE contrib_regression TO test_pgl_ddl_deploy;

SELECT pgl_ddl_deploy.add_role(oid) FROM pg_roles WHERE rolname = 'test_pgl_ddl_deploy';

SET ROLE test_pgl_ddl_deploy;

CREATE FUNCTION check_rep_tables() RETURNS TABLE (set_name TEXT, table_name TEXT)
AS 
$BODY$
BEGIN

-- Handle change from view to function rep_set_table_wrapper
IF (SELECT extversion FROM pg_extension WHERE extname = 'pgl_ddl_deploy') = ANY('{1.0,1.1,1.2,1.3}'::text[]) THEN
    RETURN QUERY EXECUTE $$
    SELECT set_name::TEXT, set_reloid::TEXT AS table_name
    FROM pgl_ddl_deploy.rep_set_table_wrapper rsr
    INNER JOIN pglogical.replication_set rs USING (set_id)
    ORDER BY set_name::TEXT, set_reloid::TEXT;$$;
ELSE
    RETURN QUERY EXECUTE $$ 
    SELECT set_name::TEXT, set_reloid::TEXT AS table_name
    FROM pgl_ddl_deploy.rep_set_table_wrapper() rsr
    INNER JOIN pglogical.replication_set rs USING (set_id)
    ORDER BY set_name::TEXT, set_reloid::TEXT;$$;
END IF;

END;
$BODY$
LANGUAGE plpgsql;

