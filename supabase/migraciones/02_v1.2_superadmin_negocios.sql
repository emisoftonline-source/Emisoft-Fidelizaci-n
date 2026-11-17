-- =====================================================================
-- EMISOFT FIDELIZACIÓN DIGITAL · MIGRACIÓN 1.2
-- Ejecutar completo en Supabase > SQL Editor.
--
-- NO borra negocios, clientes, tarjetas, sellos, programas ni canjes.
-- NO modifica contraseñas.
-- Se puede ejecutar más de una vez sin duplicar nada.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Acceso por negocio: un negocio suspendido queda bloqueado para sus
--    usuarios. El superadministrador conserva el acceso.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_business_access(p_business_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.is_superadmin() OR EXISTS (
    SELECT 1
    FROM public.memberships m
    JOIN public.businesses b ON b.id = m.business_id
    WHERE m.user_id = auth.uid()
      AND m.business_id = p_business_id
      AND m.active = true
      AND b.status = 'active'
  );
$function$;

CREATE OR REPLACE FUNCTION public.can_operate_business(p_business_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.is_superadmin() OR EXISTS (
    SELECT 1
    FROM public.memberships m
    JOIN public.businesses b ON b.id = m.business_id
    WHERE m.user_id = auth.uid()
      AND m.business_id = p_business_id
      AND m.active = true
      AND m.role IN ('admin_negocio', 'vendedor')
      AND b.status = 'active'
  );
$function$;

-- Administrador del negocio (puede configurar la fidelización).
CREATE OR REPLACE FUNCTION public.is_business_admin(p_business_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.is_superadmin() OR EXISTS (
    SELECT 1
    FROM public.memberships m
    JOIN public.businesses b ON b.id = m.business_id
    WHERE m.user_id = auth.uid()
      AND m.business_id = p_business_id
      AND m.active = true
      AND m.role = 'admin_negocio'
      AND b.status = 'active'
  );
$function$;

-- ---------------------------------------------------------------------
-- 2. Programa de fidelización: solo superadmin o admin_negocio.
--    (Sustituye la lista de roles antigua por los roles reales del ENUM.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_loyalty_program(
  p_business_id uuid,
  p_name text,
  p_stamps_required integer,
  p_reward_description text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_program public.loyalty_programs%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_business_admin(p_business_id) THEN
    RAISE EXCEPTION 'Solo el administrador del negocio puede cambiar su fidelización';
  END IF;

  IF length(trim(coalesce(p_name,''))) < 2 THEN
    RAISE EXCEPTION 'El nombre del programa es obligatorio';
  END IF;
  IF p_stamps_required IS NULL OR p_stamps_required < 1 OR p_stamps_required > 1000 THEN
    RAISE EXCEPTION 'La cantidad de sellos debe estar entre 1 y 1000';
  END IF;
  IF length(trim(coalesce(p_reward_description,''))) < 2 THEN
    RAISE EXCEPTION 'Describe el premio o beneficio';
  END IF;

  UPDATE public.loyalty_programs
  SET active = false
  WHERE business_id = p_business_id AND active = true;

  INSERT INTO public.loyalty_programs(business_id, name, stamps_required, reward_description, active)
  VALUES (p_business_id, trim(p_name), p_stamps_required, trim(p_reward_description), true)
  RETURNING * INTO v_program;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (
    p_business_id, auth.uid(), 'loyalty_program_created', 'loyalty_program', v_program.id,
    jsonb_build_object(
      'name', v_program.name,
      'stamps_required', v_program.stamps_required,
      'reward_description', v_program.reward_description
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'program_id', v_program.id,
    'name', v_program.name,
    'stamps_required', v_program.stamps_required,
    'reward_description', v_program.reward_description
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- 3. Superadmin: crear / editar negocio.
--    p_business_id NULL  -> crea un negocio nuevo con un programa inicial.
--    p_logo_url NULL     -> conserva el logo actual; '' -> quita el logo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_save_business(
  p_business_id uuid,
  p_name text,
  p_slug text,
  p_phone text,
  p_logo_url text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_slug text;
  v_biz public.businesses%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_superadmin() THEN
    RAISE EXCEPTION 'Solo el superadministrador puede gestionar negocios';
  END IF;

  IF length(trim(coalesce(p_name,''))) < 2 THEN
    RAISE EXCEPTION 'El nombre del negocio es obligatorio';
  END IF;

  -- Identificador (slug): minúsculas, sin acentos, solo letras, números y guiones.
  v_slug := lower(trim(coalesce(nullif(trim(p_slug),''), p_name)));
  v_slug := translate(v_slug, 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc');
  v_slug := trim(both '-' from regexp_replace(v_slug, '[^a-z0-9]+', '-', 'g'));
  IF length(v_slug) < 2 THEN
    RAISE EXCEPTION 'El identificador del negocio no es válido';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.businesses b
    WHERE b.slug = v_slug AND b.id IS DISTINCT FROM p_business_id
  ) THEN
    RAISE EXCEPTION 'Ya existe un negocio con el identificador "%"', v_slug;
  END IF;

  IF p_logo_url IS NOT NULL AND trim(p_logo_url) <> '' AND p_logo_url !~ '^https://' THEN
    RAISE EXCEPTION 'La dirección del logo no es válida';
  END IF;

  IF p_business_id IS NULL THEN
    INSERT INTO public.businesses(name, slug, phone, logo_url)
    VALUES (
      trim(p_name), v_slug,
      nullif(trim(coalesce(p_phone,'')), ''),
      nullif(trim(coalesce(p_logo_url,'')), '')
    )
    RETURNING * INTO v_biz;

    -- Programa inicial para que el negocio pueda registrar clientes de inmediato.
    INSERT INTO public.loyalty_programs(business_id, name, stamps_required, reward_description, active)
    VALUES (v_biz.id, 'Cliente frecuente', 10, 'Premio por completar la tarjeta', true);

    INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
    VALUES (v_biz.id, auth.uid(), 'business_created', 'business', v_biz.id,
            jsonb_build_object('name', v_biz.name, 'slug', v_biz.slug));
  ELSE
    UPDATE public.businesses
    SET name = trim(p_name),
        slug = v_slug,
        phone = nullif(trim(coalesce(p_phone,'')), ''),
        logo_url = CASE
          WHEN p_logo_url IS NULL THEN logo_url
          ELSE nullif(trim(p_logo_url), '')
        END,
        updated_at = now()
    WHERE id = p_business_id
    RETURNING * INTO v_biz;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Negocio no encontrado';
    END IF;

    INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
    VALUES (v_biz.id, auth.uid(), 'business_updated', 'business', v_biz.id,
            jsonb_build_object('name', v_biz.name, 'slug', v_biz.slug, 'logo_url', v_biz.logo_url));
  END IF;

  RETURN to_jsonb(v_biz);
END;
$function$;

-- ---------------------------------------------------------------------
-- 4. Superadmin: activar / suspender negocio.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_business_status(
  p_business_id uuid,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_biz public.businesses%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_superadmin() THEN
    RAISE EXCEPTION 'Solo el superadministrador puede cambiar el estado de un negocio';
  END IF;
  IF p_status NOT IN ('active', 'suspended') THEN
    RAISE EXCEPTION 'Estado no válido';
  END IF;

  UPDATE public.businesses
  SET status = p_status::public.business_status, updated_at = now()
  WHERE id = p_business_id
  RETURNING * INTO v_biz;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Negocio no encontrado';
  END IF;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (v_biz.id, auth.uid(),
          CASE WHEN p_status = 'active' THEN 'business_activated' ELSE 'business_suspended' END,
          'business', v_biz.id, jsonb_build_object('status', p_status));

  RETURN to_jsonb(v_biz);
END;
$function$;

-- ---------------------------------------------------------------------
-- 5. Usuarios de un negocio (nombre, correo, rol, estado).
--    El correo solo se muestra al superadmin y al admin del negocio.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_business_members(p_business_id uuid)
RETURNS TABLE(
  membership_id uuid,
  user_id uuid,
  full_name text,
  email text,
  role text,
  active boolean,
  created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_show_email boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_business_access(p_business_id) THEN
    RAISE EXCEPTION 'No tienes acceso a este negocio';
  END IF;

  v_show_email := public.is_business_admin(p_business_id);

  RETURN QUERY
  SELECT m.id,
         m.user_id,
         nullif(p.full_name, '')::text,
         CASE WHEN v_show_email THEN u.email::text ELSE NULL END,
         m.role::text,
         m.active,
         m.created_at
  FROM public.memberships m
  LEFT JOIN public.profiles p ON p.id = m.user_id
  LEFT JOIN auth.users u ON u.id = m.user_id
  WHERE m.business_id = p_business_id
  ORDER BY m.active DESC, m.created_at;
END;
$function$;

-- ---------------------------------------------------------------------
-- 6. Superadmin: activar / desactivar el acceso de un usuario a un negocio.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_member_active(
  p_membership_id uuid,
  p_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_m public.memberships%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_superadmin() THEN
    RAISE EXCEPTION 'Solo el superadministrador puede activar o desactivar usuarios';
  END IF;

  UPDATE public.memberships
  SET active = coalesce(p_active, false)
  WHERE id = p_membership_id
  RETURNING * INTO v_m;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuario del negocio no encontrado';
  END IF;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (v_m.business_id, auth.uid(),
          CASE WHEN v_m.active THEN 'member_activated' ELSE 'member_deactivated' END,
          'membership', v_m.id, jsonb_build_object('user_id', v_m.user_id));

  RETURN jsonb_build_object('success', true, 'active', v_m.active);
END;
$function$;

-- ---------------------------------------------------------------------
-- 7. Permisos de ejecución.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.is_business_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_business_admin(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.save_loyalty_program(uuid,text,integer,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_loyalty_program(uuid,text,integer,text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_save_business(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_save_business(uuid,text,text,text,text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_business_status(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_business_status(uuid,text) TO authenticated;

REVOKE ALL ON FUNCTION public.list_business_members(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_business_members(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_set_member_active(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_member_active(uuid,boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.redeem_loyalty_reward(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redeem_loyalty_reward(uuid,uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 8. Logos: bucket público de solo lectura; solo el superadmin sube,
--    cambia o borra archivos. Máximo 2 MB; PNG, JPG o WEBP.
-- ---------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('business-logos', 'business-logos', true, 2097152,
        ARRAY['image/png', 'image/jpeg', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS "emisoft logos insert superadmin" ON storage.objects;
CREATE POLICY "emisoft logos insert superadmin" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'business-logos' AND public.is_superadmin());

DROP POLICY IF EXISTS "emisoft logos update superadmin" ON storage.objects;
CREATE POLICY "emisoft logos update superadmin" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'business-logos' AND public.is_superadmin())
  WITH CHECK (bucket_id = 'business-logos' AND public.is_superadmin());

DROP POLICY IF EXISTS "emisoft logos delete superadmin" ON storage.objects;
CREATE POLICY "emisoft logos delete superadmin" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'business-logos' AND public.is_superadmin());

COMMIT;

-- Comprobación rápida (debe devolver 6 filas):
SELECT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('is_business_admin','admin_save_business','admin_set_business_status',
                    'list_business_members','admin_set_member_active','save_loyalty_program')
ORDER BY 1;
