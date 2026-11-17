-- =====================================================================
-- EMISOFT FIDELIZACIÓN DIGITAL · MIGRACIÓN 1.4 · CAMBIO DE CONTRASEÑA
-- Ejecutar completo en Supabase > SQL Editor (después de la 1.3.1).
--
-- * Los usuarios de negocio deben cambiar su contraseña en el primer
--   ingreso y después de cada restablecimiento hecho por el superadmin.
-- * Mientras no la cambien, la base de datos les niega el acceso a los
--   datos del negocio (no basta con saltarse la pantalla).
-- * El aviso se quita solo cuando la contraseña cambia de verdad.
-- No borra datos. Se puede ejecutar más de una vez.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Indicador "debe cambiar contraseña".
--    Solo la primera vez que se crea la columna, se marca a los usuarios
--    de negocio que ya existen (sus contraseñas las puso el superadmin).
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles'
      AND column_name = 'must_change_password'
  ) THEN
    ALTER TABLE public.profiles
      ADD COLUMN must_change_password boolean NOT NULL DEFAULT false;

    UPDATE public.profiles p
    SET must_change_password = true
    WHERE p.role <> 'superadmin'
      AND EXISTS (SELECT 1 FROM public.memberships m WHERE m.user_id = p.id);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 2. Al cambiar la contraseña (tabla auth.users), se quita el aviso.
--    El restablecimiento del superadmin lo vuelve a activar después
--    (lo hace la Edge Function emisoft-admin).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.on_auth_password_changed()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.encrypted_password IS DISTINCT FROM OLD.encrypted_password THEN
    UPDATE public.profiles
    SET must_change_password = false, updated_at = now()
    WHERE id = NEW.id AND must_change_password;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS emisoft_on_password_changed ON auth.users;
CREATE TRIGGER emisoft_on_password_changed
  AFTER UPDATE OF encrypted_password ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.on_auth_password_changed();

-- ---------------------------------------------------------------------
-- 3. Sin contraseña propia, no hay acceso a los datos del negocio.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.password_change_pending()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT coalesce((SELECT p.must_change_password FROM public.profiles p WHERE p.id = auth.uid()), false);
$function$;

CREATE OR REPLACE FUNCTION public.has_business_access(p_business_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.is_superadmin() OR (
    NOT public.password_change_pending()
    AND EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.businesses b ON b.id = m.business_id
      WHERE m.user_id = auth.uid()
        AND m.business_id = p_business_id
        AND m.active = true
        AND b.status = 'active'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.can_operate_business(p_business_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.is_superadmin() OR (
    NOT public.password_change_pending()
    AND EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.businesses b ON b.id = m.business_id
      WHERE m.user_id = auth.uid()
        AND m.business_id = p_business_id
        AND m.active = true
        AND m.role IN ('admin_negocio', 'vendedor')
        AND b.status = 'active'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_business_admin(p_business_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.is_superadmin() OR (
    NOT public.password_change_pending()
    AND EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.businesses b ON b.id = m.business_id
      WHERE m.user_id = auth.uid()
        AND m.business_id = p_business_id
        AND m.active = true
        AND m.role = 'admin_negocio'
        AND b.status = 'active'
    )
  );
$function$;

-- ---------------------------------------------------------------------
-- 4. Registro en la auditoría cuando el propio usuario cambia su clave.
--    Solo registra si la contraseña realmente cambió hace un momento.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_own_password_changed()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_pending boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sesión requerida';
  END IF;
  v_pending := public.password_change_pending();
  IF NOT v_pending THEN
    INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
    SELECT m.business_id, auth.uid(), 'password_changed', 'membership', m.id, '{}'::jsonb
    FROM public.memberships m
    WHERE m.user_id = auth.uid();
  END IF;
  RETURN jsonb_build_object('success', NOT v_pending);
END;
$function$;

REVOKE ALL ON FUNCTION public.password_change_pending() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.password_change_pending() TO authenticated;
REVOKE ALL ON FUNCTION public.log_own_password_changed() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_own_password_changed() TO authenticated;
REVOKE ALL ON FUNCTION public.on_auth_password_changed() FROM PUBLIC, anon, authenticated;

COMMIT;

-- Comprobación: usuarios y si deben cambiar su contraseña.
SELECT u.email, p.role, p.must_change_password AS debe_cambiar
FROM auth.users u JOIN public.profiles p ON p.id = u.id
ORDER BY p.role, u.email;
