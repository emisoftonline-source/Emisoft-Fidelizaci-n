-- =====================================================================
-- EMISOFT FIDELIZACIÓN DIGITAL · MIGRACIÓN 1.3.1 · SORPRESAS Y RUBROS
-- Ejecutar completo en Supabase > SQL Editor (después de la 1.3).
--
-- Agrega:
--   * Ícono por premio intermedio (🎁, 🎉, 💸, ...).
--   * Premios "sorpresa": el cliente no ve cuál es hasta alcanzarlo.
--   * Rubro del negocio (restaurante, peluquería, tienda, ...).
-- No borra datos. Se puede ejecutar más de una vez.
-- =====================================================================

BEGIN;

ALTER TABLE public.loyalty_milestones
  ADD COLUMN IF NOT EXISTS icon text,
  ADD COLUMN IF NOT EXISTS is_surprise boolean NOT NULL DEFAULT false;

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS category text;

-- ---------------------------------------------------------------------
-- Guardar política: igual que en la 1.3, y además lee "icon" y
-- "surprise" de cada premio intermedio.
--   p_milestones: [{"stamps_at":3,"reward":"Postre gratis","icon":"🎁","surprise":true}, ...]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_loyalty_program_v2(
  p_business_id uuid,
  p_name text,
  p_stamps_required integer,
  p_reward_description text,
  p_stamp_rule text,
  p_milestones jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_program public.loyalty_programs%rowtype;
  v_item jsonb;
  v_at integer;
  v_reward text;
  v_seen integer[] := '{}';
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
    RAISE EXCEPTION 'Describe el premio final';
  END IF;
  IF length(coalesce(p_stamp_rule,'')) > 300 THEN
    RAISE EXCEPTION 'La regla del sello es demasiado larga';
  END IF;
  IF p_milestones IS NOT NULL AND jsonb_typeof(p_milestones) <> 'array' THEN
    RAISE EXCEPTION 'Formato de premios intermedios no válido';
  END IF;
  IF jsonb_array_length(coalesce(p_milestones,'[]')) > 10 THEN
    RAISE EXCEPTION 'Máximo 10 premios intermedios';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(p_milestones,'[]')) LOOP
    BEGIN
      v_at := (v_item->>'stamps_at')::integer;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'El número de sello de un premio intermedio no es válido';
    END;
    v_reward := trim(coalesce(v_item->>'reward',''));
    IF v_at IS NULL OR v_at < 1 OR v_at >= p_stamps_required THEN
      RAISE EXCEPTION 'Los premios intermedios deben estar entre el sello 1 y el %', p_stamps_required - 1;
    END IF;
    IF v_at = ANY(v_seen) THEN
      RAISE EXCEPTION 'Hay dos premios intermedios en el sello %', v_at;
    END IF;
    IF length(v_reward) < 2 OR length(v_reward) > 300 THEN
      RAISE EXCEPTION 'Describe el premio del sello %', v_at;
    END IF;
    IF length(coalesce(v_item->>'icon','')) > 16 THEN
      RAISE EXCEPTION 'Ícono no válido en el sello %', v_at;
    END IF;
    v_seen := v_seen || v_at;
  END LOOP;

  UPDATE public.loyalty_programs SET active = false
  WHERE business_id = p_business_id AND active = true;

  INSERT INTO public.loyalty_programs(business_id, name, stamps_required, reward_description, stamp_rule, active)
  VALUES (p_business_id, trim(p_name), p_stamps_required, trim(p_reward_description),
          nullif(trim(coalesce(p_stamp_rule,'')), ''), true)
  RETURNING * INTO v_program;

  INSERT INTO public.loyalty_milestones(business_id, program_id, stamps_at, reward_description, icon, is_surprise)
  SELECT p_business_id, v_program.id, (e->>'stamps_at')::integer, trim(e->>'reward'),
         nullif(trim(coalesce(e->>'icon','')), ''),
         coalesce((e->>'surprise')::boolean, false)
  FROM jsonb_array_elements(coalesce(p_milestones,'[]')) e;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (p_business_id, auth.uid(), 'loyalty_program_created', 'loyalty_program', v_program.id,
    jsonb_build_object(
      'name', v_program.name,
      'stamps_required', v_program.stamps_required,
      'reward_description', v_program.reward_description,
      'stamp_rule', v_program.stamp_rule,
      'milestones', coalesce(p_milestones,'[]')
    ));

  RETURN jsonb_build_object('success', true, 'program_id', v_program.id);
END;
$function$;

-- ---------------------------------------------------------------------
-- Rubro del negocio (solo superadmin).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_business_category(
  p_business_id uuid,
  p_category text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_superadmin() THEN
    RAISE EXCEPTION 'Solo el superadministrador puede cambiar el rubro';
  END IF;
  IF length(coalesce(p_category,'')) > 60 THEN
    RAISE EXCEPTION 'Rubro no válido';
  END IF;
  UPDATE public.businesses
  SET category = nullif(trim(coalesce(p_category,'')), ''), updated_at = now()
  WHERE id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Negocio no encontrado';
  END IF;
  RETURN jsonb_build_object('success', true);
END;
$function$;

-- ---------------------------------------------------------------------
-- Tarjeta pública: agrega ícono y sorpresa. El texto de un premio
-- sorpresa NO se envía al cliente hasta que alcance ese sello.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_public_card(p_token text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_customer public.customers%rowtype;
  v_business public.businesses%rowtype;
  v_card public.loyalty_cards%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_since timestamptz;
  v_count integer;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{32,128}$' THEN
    RAISE EXCEPTION 'Tarjeta no válida';
  END IF;

  SELECT * INTO v_customer FROM public.customers WHERE qr_token = p_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tarjeta no encontrada';
  END IF;

  SELECT * INTO v_business FROM public.businesses WHERE id = v_customer.business_id;
  IF NOT FOUND OR v_business.status <> 'active' THEN
    RAISE EXCEPTION 'Esta tarjeta no está disponible por el momento';
  END IF;

  SELECT * INTO v_card FROM public.loyalty_cards
  WHERE customer_id = v_customer.id AND business_id = v_customer.business_id
  ORDER BY created_at DESC LIMIT 1;

  IF v_card.id IS NOT NULL THEN
    SELECT * INTO v_program FROM public.loyalty_programs WHERE id = v_card.program_id;
    SELECT max(redeemed_at) INTO v_since FROM public.loyalty_redemptions
    WHERE card_id = v_card.id AND milestone_id IS NULL;
  END IF;
  v_count := coalesce(v_card.stamps_count, 0);

  RETURN jsonb_build_object(
    'business_name',   v_business.name,
    'business_logo',   v_business.logo_url,
    'business_phone',  v_business.phone,
    'customer_name',   split_part(trim(v_customer.full_name), ' ', 1),
    'member_since',    v_customer.created_at,
    'has_card',        v_card.id IS NOT NULL,
    'program_name',    v_program.name,
    'stamp_rule',      v_program.stamp_rule,
    'stamps_count',    v_count,
    'stamps_required', v_program.stamps_required,
    'reward',          v_program.reward_description,
    'completed',       coalesce(v_card.stamps_count >= v_program.stamps_required, false),
    'milestones', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'stamps_at', m.stamps_at,
               'reward', CASE WHEN m.is_surprise AND v_count < m.stamps_at
                              THEN NULL ELSE m.reward_description END,
               'icon', m.icon,
               'surprise', m.is_surprise,
               'reached', v_count >= m.stamps_at,
               'redeemed', m.id = ANY(coalesce(v_card.milestones_redeemed, '{}'))
             ) ORDER BY m.stamps_at)
      FROM public.loyalty_milestones m WHERE m.program_id = v_program.id
    ), '[]'::jsonb),
    'recent_stamps', coalesce((
      SELECT jsonb_agg(s.created_at ORDER BY s.created_at DESC)
      FROM (
        SELECT created_at FROM public.stamps
        WHERE card_id = v_card.id AND created_at > coalesce(v_since, '-infinity'::timestamptz)
        ORDER BY created_at DESC LIMIT 100
      ) s
    ), '[]'::jsonb),
    'redemptions', coalesce((
      SELECT jsonb_agg(jsonb_build_object('date', r.redeemed_at, 'reward', r.reward_description)
                       ORDER BY r.redeemed_at DESC)
      FROM (
        SELECT redeemed_at, reward_description FROM public.loyalty_redemptions
        WHERE customer_id = v_customer.id
        ORDER BY redeemed_at DESC LIMIT 20
      ) r
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.save_loyalty_program_v2(uuid,text,integer,text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_loyalty_program_v2(uuid,text,integer,text,text,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_set_business_category(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_business_category(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_card(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_card(text) TO anon, authenticated;

COMMIT;

-- Comprobación (debe devolver 2 filas: category e is_surprise):
SELECT table_name, column_name FROM information_schema.columns
WHERE table_schema = 'public'
  AND ((table_name = 'businesses' AND column_name = 'category')
    OR (table_name = 'loyalty_milestones' AND column_name = 'is_surprise'))
ORDER BY 1;
