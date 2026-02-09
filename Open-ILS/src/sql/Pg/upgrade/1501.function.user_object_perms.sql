BEGIN;

SELECT evergreen.upgrade_deps_block_check('1501', :eg_version);

ALTER FUNCTION permission.usr_has_home_perm STABLE;
ALTER FUNCTION permission.usr_has_work_perm STABLE;
ALTER FUNCTION permission.usr_has_object_perm ( INT, TEXT, TEXT, TEXT ) STABLE;
ALTER FUNCTION permission.usr_has_perm STABLE;
ALTER FUNCTION permission.usr_has_perm_at_nd STABLE;
ALTER FUNCTION permission.usr_has_perm_at_all_nd STABLE;
ALTER FUNCTION permission.usr_has_perm_at STABLE;
ALTER FUNCTION permission.usr_has_perm_at_all STABLE;

CREATE OR REPLACE FUNCTION evergreen.setup_delete_protect_rule (
    t_schema TEXT,
    t_table TEXT,
    t_additional TEXT DEFAULT '',
    t_pkey TEXT DEFAULT 'id',
    t_deleted TEXT DEFAULT 'deleted'
) RETURNS VOID AS $$
DECLARE
    rule_name   TEXT;
    table_name  TEXT;
    fq_pkey     TEXT;
BEGIN

    rule_name := 'protect_' || t_schema || '_' || t_table || '_delete';
    table_name := t_schema || '.' || t_table;
    fq_pkey := table_name || '.' || t_pkey;

    EXECUTE 'DROP RULE IF EXISTS ' || rule_name || ' ON ' || table_name;
    EXECUTE 'CREATE RULE ' || rule_name
            || ' AS ON DELETE TO ' || table_name
            || ' DO INSTEAD (UPDATE ' || table_name
            || '   SET ' || t_deleted || ' = TRUE '
            || '   WHERE OLD.' || t_pkey || ' = ' || fq_pkey
            || '   ; ' || t_additional || ')';

END;
$$ STRICT LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION permission.usr_has_object_perm ( iuser INT, tperm TEXT, obj_type TEXT, obj_id TEXT, target_ou INT ) RETURNS BOOL AS $$
DECLARE
    r_usr   actor.usr%ROWTYPE;
    r_perm  permission.perm_list%ROWTYPE;
    res     BOOL;
BEGIN

    SELECT * INTO r_usr FROM actor.usr WHERE id = iuser;
    SELECT * INTO r_perm FROM permission.perm_list WHERE code = tperm;

    IF r_usr.active = FALSE THEN
        RETURN FALSE;
    END IF;

    IF r_usr.super_user = TRUE THEN
        RETURN TRUE;
    END IF;

    SELECT TRUE INTO res FROM permission.usr_object_perm_map WHERE perm = r_perm.id AND usr = r_usr.id AND object_type = obj_type AND object_id = obj_id;

    IF FOUND THEN
        RETURN TRUE;
    END IF;

    IF target_ou > -1 THEN
        RETURN permission.usr_has_perm( iuser, tperm, target_ou);
    END IF;

    RETURN FALSE;

END;
$$ LANGUAGE PLPGSQL STABLE;

-- Start trimming back RULEs, they're starting to make things too hard.  Trigger time!
CREATE OR REPLACE FUNCTION evergreen.raise_protected_row_exception() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Cannot % %.% with % of %', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME, COALESCE(TG_ARGV[0]::TEXT,'id'), COALESCE(TG_ARGV[1]::TEXT,'-1');
END;
$$ LANGUAGE plpgsql;

DROP RULE IF EXISTS protect_bre_id_neg1 ON biblio.record_entry;
CREATE TRIGGER protect_bre_id_neg1
  BEFORE UPDATE ON biblio.record_entry
  FOR EACH ROW WHEN (NEW.deleted = TRUE AND OLD.deleted = FALSE AND OLD.id = -1)
  EXECUTE PROCEDURE evergreen.raise_protected_row_exception();

DROP RULE IF EXISTS protect_acn_id_neg1 ON asset.call_number;
CREATE TRIGGER protect_acn_id_neg1
  BEFORE UPDATE ON asset.call_number
  FOR EACH ROW WHEN (OLD.id = -1)
  EXECUTE PROCEDURE evergreen.raise_protected_row_exception();

-- Open-ILS/src/sql/Pg/005.schema.actors.sql
DROP RULE IF EXISTS protect_user_delete ON actor.usr;
SELECT evergreen.setup_delete_protect_rule('actor','usr');

DROP RULE IF EXISTS protect_usr_message_delete ON actor.usr_message;
SELECT evergreen.setup_delete_protect_rule('actor','usr_message');

-- Open-ILS/src/sql/Pg/011.schema.authority.sql
DROP RULE IF EXISTS protect_authority_rec_delete ON authority.record_entry;
SELECT evergreen.setup_delete_protect_rule('authority','record_entry','DELETE FROM authority.full_rec WHERE record = OLD.id');

-- Open-ILS/src/sql/Pg/040.schema.asset.sql
DROP RULE IF EXISTS protect_copy_delete ON asset.copy;
SELECT evergreen.setup_delete_protect_rule('asset','copy');

DROP RULE IF EXISTS protect_cn_delete ON asset.call_number;
SELECT evergreen.setup_delete_protect_rule('asset','call_number');

-- Open-ILS/src/sql/Pg/210.schema.serials.sql
DROP RULE IF EXISTS protect_mfhd_delete ON serial.record_entry;
SELECT evergreen.setup_delete_protect_rule('serial','record_entry');

DROP RULE IF EXISTS protect_serial_unit_delete ON serial.unit;
SELECT evergreen.setup_delete_protect_rule('serial','unit');

-- Open-ILS/src/sql/Pg/800.fkeys.sql
DROP RULE IF EXISTS protect_bib_rec_delete ON biblio.record_entry;
SELECT evergreen.setup_delete_protect_rule('biblio','record_entry');

DROP RULE IF EXISTS protect_mono_part_delete ON biblio.record_entry;
SELECT evergreen.setup_delete_protect_rule('biblio','monograph_part','DELETE FROM asset.copy_part_map WHERE part = OLD.id');

DROP RULE IF EXISTS protect_copy_location_delete ON asset.copy_location;
SELECT evergreen.setup_delete_protect_rule(
    'asset', 'copy_location',
    'SELECT asset.check_delete_copy_location(OLD.id);'
      || ' UPDATE acq.lineitem_detail SET location = NULL WHERE location = OLD.id;'
      || ' DELETE FROM asset.copy_location_order WHERE location = OLD.id;'
      || ' DELETE FROM asset.copy_location_group_map WHERE location = OLD.id;'
      || ' DELETE FROM config.circ_limit_set_copy_loc_map WHERE copy_loc = OLD.id;'
);

COMMIT;

