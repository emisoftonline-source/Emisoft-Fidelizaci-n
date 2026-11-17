-- EMISOFT FIDELIZACIÓN: actualización para programas por negocio y canjes.
-- Ejecutar en Supabase > SQL Editor como postgres.
-- Esta migración conserva programas y tarjetas existentes.

BEGIN;

-- La función de alta debe asignar a clientes nuevos el programa activo más reciente.
CREATE OR REPLACE FUNCTION public.create_customer_card(
  p_business_id uuid,
  p_full_name text,
  p_phone text
)
RETURNS TABLE(customer_id uuid, card_id uuid, qr_token text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- customer_id también es una columna de salida (RETURNS TABLE).
-- Priorizar las columnas de las tablas evita la ambigüedad en ON CONFLICT.
#variable_conflict use_column
DECLARE
  v_program public.loyalty_programs%rowtype;
  v_customer public.customers%rowtype;
  v_card public.loyalty_cards%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_operate_business(p_business_id) THEN
    RAISE EXCEPTION 'No tienes permiso para operar este negocio';
  END IF;

  IF length(trim(coalesce(p_full_name,''))) < 2
     OR length(trim(coalesce(p_phone,''))) < 6 THEN
    RAISE EXCEPTION 'Nombre y celular son obligatorios';
  END IF;

  SELECT * INTO v_program
  FROM public.loyalty_programs
  WHERE business_id = p_business_id AND active = true
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El negocio no tiene un programa activo';
  END IF;

  INSERT INTO public.customers(business_id, full_name, phone, created_by)
  VALUES (p_business_id, trim(p_full_name), trim(p_phone), auth.uid())
  ON CONFLICT (business_id, phone) DO UPDATE
    SET full_name = excluded.full_name
  RETURNING * INTO v_customer;

  INSERT INTO public.loyalty_cards(business_id, customer_id, program_id)
  VALUES (p_business_id, v_customer.id, v_program.id)
  ON CONFLICT (customer_id, program_id) DO UPDATE
    SET customer_id = excluded.customer_id
  RETURNING * INTO v_card;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id)
  VALUES (p_business_id, auth.uid(), 'customer_card_created', 'customer', v_customer.id);

  RETURN QUERY SELECT v_customer.id, v_card.id, v_customer.qr_token;
END;
$function$;

-- Las tarjetas antiguas continúan usando su propio programa aunque ya no esté activo.
CREATE OR REPLACE FUNCTION public.add_stamp(
  p_business_id uuid,
  p_qr_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_customer public.customers%rowtype;
  v_card public.loyalty_cards%rowtype;
  v_program public.loyalty_programs%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_operate_business(p_business_id) THEN
    RAISE EXCEPTION 'No tienes permiso para registrar sellos';
  END IF;

  SELECT * INTO v_customer
  FROM public.customers
  WHERE business_id = p_business_id AND qr_token = p_qr_token;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código QR no válido para este negocio';
  END IF;

  SELECT c.* INTO v_card
  FROM public.loyalty_cards c
  WHERE c.customer_id = v_customer.id
    AND c.business_id = p_business_id
  ORDER BY c.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El cliente no tiene tarjeta';
  END IF;

  SELECT * INTO v_program
  FROM public.loyalty_programs
  WHERE id = v_card.program_id
    AND business_id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el programa asociado a la tarjeta';
  END IF;

  IF v_card.stamps_count >= v_program.stamps_required THEN
    RAISE EXCEPTION 'La tarjeta está completa; debe canjearse antes de continuar';
  END IF;

  INSERT INTO public.stamps(business_id, card_id, customer_id, created_by)
  VALUES (p_business_id, v_card.id, v_customer.id, auth.uid());

  UPDATE public.loyalty_cards
  SET stamps_count = stamps_count + 1,
      completed_at = CASE
        WHEN stamps_count + 1 >= v_program.stamps_required THEN now()
        ELSE NULL
      END
  WHERE id = v_card.id
  RETURNING * INTO v_card;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (
    p_business_id, auth.uid(), 'stamp_added', 'loyalty_card', v_card.id,
    jsonb_build_object('customer_id', v_customer.id, 'stamps_count', v_card.stamps_count)
  );

  RETURN jsonb_build_object(
    'customer_name', v_customer.full_name,
    'stamps_count', v_card.stamps_count,
    'stamps_required', v_program.stamps_required,
    'completed', v_card.stamps_count >= v_program.stamps_required
  );
END;
$function$;

-- Crear una nueva versión de programa. Solo superadmin o responsables del negocio.
CREATE OR REPLACE FUNCTION public.save_loyalty_program(
  p_business_id uuid,
  p_name text,
  p_stamps_required integer,
  p_reward_description text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_program public.loyalty_programs%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_operate_business(p_business_id) THEN
    RAISE EXCEPTION 'No tienes permiso para configurar este negocio';
  END IF;

  -- role es ENUM (app_role); convertirlo a texto evita que COALESCE
  -- intente convertir una cadena vacía al ENUM.
  SELECT p.role::text INTO v_role
  FROM public.profiles AS p
  WHERE p.id = auth.uid();

  IF coalesce(v_role,'') <> 'superadmin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.memberships m
       WHERE m.user_id = auth.uid()
         AND m.business_id = p_business_id
         AND m.active = true
         -- memberships.role también puede ser ENUM; comparar como texto.
         AND lower(coalesce(m.role::text,'')) IN
           ('admin','administrador','owner','admin_negocio','gerente','gerente_sucursal')
     ) THEN
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

  INSERT INTO public.loyalty_programs(
    business_id, name, stamps_required, reward_description, active
  )
  VALUES (
    p_business_id, trim(p_name), p_stamps_required,
    trim(p_reward_description), true
  )
  RETURNING * INTO v_program;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (
    p_business_id, auth.uid(), 'loyalty_program_created',
    'loyalty_program', v_program.id,
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

REVOKE ALL ON FUNCTION public.save_loyalty_program(uuid,text,integer,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_loyalty_program(uuid,text,integer,text) TO authenticated;

-- Mantener el acceso de las funciones existentes para usuarios autenticados.
REVOKE ALL ON FUNCTION public.add_stamp(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_stamp(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.create_customer_card(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_customer_card(uuid,text,text) TO authenticated;

COMMIT;
