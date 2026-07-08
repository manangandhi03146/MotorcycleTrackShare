-- ============================================================
-- RaceLine — Migration 008: Group Ownership Cap
-- Run AFTER 007_social_rls.sql
--
-- Free accounts can OWN up to 5 groups. Joining other groups is not
-- capped. This is the server-side enforcement — the iOS app also
-- checks the cap before showing the Create sheet, but a
-- misbehaving client shouldn't be able to bypass it.
--
-- If a Pro entitlement layer lands later, extend
-- `check_group_ownership_limit` to look up the caller's tier from a
-- `pro_entitlements` table (or similar) and skip the cap when
-- entitled.
-- ============================================================

CREATE OR REPLACE FUNCTION check_group_ownership_limit()
RETURNS TRIGGER AS $$
DECLARE
    owned_count INTEGER;
    max_owned CONSTANT INTEGER := 5;
BEGIN
    SELECT COUNT(*) INTO owned_count
    FROM groups
    WHERE owner_id = NEW.owner_id;

    IF owned_count >= max_owned THEN
        RAISE EXCEPTION 'Free accounts can only create up to % groups', max_owned
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS enforce_group_ownership_limit ON groups;
CREATE TRIGGER enforce_group_ownership_limit
    BEFORE INSERT ON groups
    FOR EACH ROW EXECUTE FUNCTION check_group_ownership_limit();
