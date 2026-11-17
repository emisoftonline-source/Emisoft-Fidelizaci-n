-- =====================================================================
-- EMISOFT FIDELIZACIÓN DIGITAL · MIGRACIÓN 1.3 · POLÍTICAS POR NEGOCIO
-- Ejecutar completo en Supabase > SQL Editor (después de la 1.2.2).
--
-- Agrega:
--   * Regla del sello por programa ("1 sello por cada 2 cuartos de pollo").
--   * Premios intermedios ("al 5º sello: 50% de descuento").
--   * Sumar varios sellos en una sola operación.
--
-- No borra datos. Los programas y tarjetas actuales siguen funcionando
-- igual (sin premios intermedios hasta que el negocio los configure).
-- Se puede ejecutar más de una vez.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Estructura
-- ---------------------------------------------------------------------
ALTER TABLE public.loyalty_programs
  ADD COLUMN IF NOT EXISTS stamp_rule text;

CREATE TABLE IF NOT EXISTS public.loyalty_milestones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id),
  program_id uuid NOT NULL REFERENCES public.loyalty_programs(id),
  stamps_at integer NOT NULL CHECK (stamps_at >= 1),
  reward_description text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (program_id, stamps_at)
);

ALTER TABLE public.loyalty_milestones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "milestones access" ON public.loyalty_milestones;
CREATE POLICY "milestones access" ON public.loyalty_milestones
  FOR SELECT USING (public.has_business_access(business_id));
GRANT SELECT ON public.loyalty_milestones TO authenticated;

-- Premios intermedios ya canjeados en el ciclo actual de la tarjeta.
ALTER TABLE public.loyalty_cards
  ADD COLUMN IF NOT EXISTS milestones_redeemed uuid[] NOT NULL DEFAULT '{}';

-- En el historial: NULL = premio final; con valor = premio intermedio.
ALTER TABLE public.loyalty_redemptions
  ADD COLUMN IF NOT EXISTS milestone_id uuid REFERENCES public.loyalty_milestones(id);

-- ---------------------------------------------------------------------
-- 2. Guardar programa con regla y premios intermedios.
--    p_milestones: [{"stamps_at": 5, "reward": "50% de descuento"}, ...]
--    Crea una versión nueva; las tarjetas existentes conservan la suya.
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

  -- Validar premios intermedios antes de guardar.
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
    v_seen := v_seen || v_at;
  END LOOP;

  UPDATE public.loyalty_programs SET active = false
  WHERE business_id = p_business_id AND active = true;

  INSERT INTO public.loyalty_programs(business_id, name, stamps_required, reward_description, stamp_rule, active)
  VALUES (p_business_id, trim(p_name), p_stamps_required, trim(p_reward_description),
          nullif(trim(coalesce(p_stamp_rule,'')), ''), true)
  RETURNING * INTO v_program;

  INSERT INTO public.loyalty_milestones(business_id, program_id, stamps_at, reward_description)
  SELECT p_business_id, v_program.id, (e->>'stamps_at')::integer, trim(e->>'reward')
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
-- 3. Sumar uno o varios sellos.
--    Devuelve también los premios intermedios que se desbloquearon.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_stamps(
  p_business_id uuid,
  p_qr_token text,
  p_quantity integer
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_customer public.customers%rowtype;
  v_card public.loyalty_cards%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_before integer;
  v_unlocked jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_operate_business(p_business_id) THEN
    RAISE EXCEPTION 'No tienes permiso para registrar sellos';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 100 THEN
    RAISE EXCEPTION 'La cantidad de sellos debe estar entre 1 y 100';
  END IF;

  SELECT * INTO v_customer FROM public.customers
  WHERE business_id = p_business_id AND qr_token = lower(trim(p_qr_token));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código QR no válido para este negocio';
  END IF;

  SELECT c.* INTO v_card FROM public.loyalty_cards c
  WHERE c.customer_id = v_customer.id AND c.business_id = p_business_id
  ORDER BY c.created_at DESC LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El cliente no tiene tarjeta';
  END IF;

  SELECT * INTO v_program FROM public.loyalty_programs
  WHERE id = v_card.program_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el programa asociado a la tarjeta';
  END IF;

  v_before := v_card.stamps_count;
  IF v_before >= v_program.stamps_required THEN
    RAISE EXCEPTION 'La tarjeta está completa; debe canjearse el premio antes de sumar más sellos';
  END IF;
  IF v_before + p_quantity > v_program.stamps_required THEN
    RAISE EXCEPTION 'A este cliente solo le faltan % sello(s) para completar la tarjeta', v_program.stamps_required - v_before;
  END IF;

  INSERT INTO public.stamps(business_id, card_id, customer_id, created_by)
  SELECT p_business_id, v_card.id, v_customer.id, auth.uid()
  FROM generate_series(1, p_quantity);

  UPDATE public.loyalty_cards
  SET stamps_count = stamps_count + p_quantity,
      completed_at = CASE WHEN stamps_count + p_quantity >= v_program.stamps_required THEN now() ELSE NULL END
  WHERE id = v_card.id
  RETURNING * INTO v_card;

  SELECT coalesce(jsonb_agg(jsonb_build_object('stamps_at', m.stamps_at, 'reward', m.reward_description)
                            ORDER BY m.stamps_at), '[]')
  INTO v_unlocked
  FROM public.loyalty_milestones m
  WHERE m.program_id = v_program.id
    AND m.stamps_at > v_before AND m.stamps_at <= v_card.stamps_count;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (p_business_id, auth.uid(), 'stamp_added', 'loyalty_card', v_card.id,
    jsonb_build_object('customer_id', v_customer.id, 'quantity', p_quantity,
                       'stamps_count', v_card.stamps_count));

  RETURN jsonb_build_object(
    'customer_name', v_customer.full_name,
    'quantity', p_quantity,
    'stamps_count', v_card.stamps_count,
    'stamps_required', v_program.stamps_required,
    'completed', v_card.stamps_count >= v_program.stamps_required,
    'unlocked', v_unlocked
  );
END;
$function$;

-- La función anterior (1 sello) sigue existiendo y usa la nueva.
CREATE OR REPLACE FUNCTION public.add_stamp(p_business_id uuid, p_qr_token text)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.add_stamps(p_business_id, p_qr_token, 1);
$function$;

-- ---------------------------------------------------------------------
-- 4. Canjear un premio intermedio (no reinicia la tarjeta).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_milestone(
  p_business_id uuid,
  p_card_id uuid,
  p_milestone_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_card public.loyalty_cards%rowtype;
  v_m public.loyalty_milestones%rowtype;
  v_customer public.customers%rowtype;
  v_redemption_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_operate_business(p_business_id) THEN
    RAISE EXCEPTION 'No tienes permiso para realizar este canje';
  END IF;

  SELECT * INTO v_card FROM public.loyalty_cards
  WHERE id = p_card_id AND business_id = p_business_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tarjeta no encontrada';
  END IF;

  SELECT * INTO v_m FROM public.loyalty_milestones
  WHERE id = p_milestone_id AND program_id = v_card.program_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ese premio no corresponde al programa de la tarjeta';
  END IF;

  IF v_card.stamps_count < v_m.stamps_at THEN
    RAISE EXCEPTION 'El cliente todavía no llega al sello %', v_m.stamps_at;
  END IF;
  IF v_m.id = ANY(v_card.milestones_redeemed) THEN
    RAISE EXCEPTION 'Este premio ya fue canjeado en el ciclo actual';
  END IF;

  SELECT * INTO v_customer FROM public.customers WHERE id = v_card.customer_id;

  INSERT INTO public.loyalty_redemptions(
    business_id, card_id, customer_id, program_id, stamps_count,
    reward_description, redeemed_by, milestone_id)
  VALUES (p_business_id, v_card.id, v_card.customer_id, v_card.program_id, v_card.stamps_count,
          v_m.reward_description, auth.uid(), v_m.id)
  RETURNING id INTO v_redemption_id;

  UPDATE public.loyalty_cards
  SET milestones_redeemed = array_append(milestones_redeemed, v_m.id)
  WHERE id = v_card.id;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (p_business_id, auth.uid(), 'milestone_redeemed', 'loyalty_card', v_card.id,
    jsonb_build_object('redemption_id', v_redemption_id, 'customer_id', v_card.customer_id,
                       'reward', v_m.reward_description, 'stamps', v_m.stamps_at));

  RETURN jsonb_build_object(
    'success', true,
    'customer_name', v_customer.full_name,
    'reward', v_m.reward_description,
    'message', 'Premio intermedio canjeado'
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- 5. Premio final: igual que antes, y además reinicia los premios
--    intermedios para el nuevo ciclo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_loyalty_reward(p_business_id uuid, p_card_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_card public.loyalty_cards%ROWTYPE;
  v_program public.loyalty_programs%ROWTYPE;
  v_customer public.customers%ROWTYPE;
  v_redemption_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_operate_business(p_business_id) THEN
    RAISE EXCEPTION 'No tienes permiso para realizar este canje';
  END IF;

  SELECT * INTO v_card FROM public.loyalty_cards
  WHERE id = p_card_id AND business_id = p_business_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tarjeta no encontrada';
  END IF;

  SELECT * INTO v_program FROM public.loyalty_programs
  WHERE id = v_card.program_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Programa de fidelización no encontrado';
  END IF;

  SELECT * INTO v_customer FROM public.customers
  WHERE id = v_card.customer_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;

  IF v_card.stamps_count < v_program.stamps_required THEN
    RAISE EXCEPTION 'La tarjeta todavía no está completa';
  END IF;

  INSERT INTO public.loyalty_redemptions(
    business_id, card_id, customer_id, program_id, stamps_count, reward_description, redeemed_by)
  VALUES (p_business_id, v_card.id, v_customer.id, v_program.id, v_card.stamps_count,
          v_program.reward_description, auth.uid())
  RETURNING id INTO v_redemption_id;

  UPDATE public.loyalty_cards
  SET stamps_count = 0, completed_at = NULL, milestones_redeemed = '{}'
  WHERE id = v_card.id;

  INSERT INTO public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  VALUES (p_business_id, auth.uid(), 'reward_redeemed', 'loyalty_card', v_card.id,
    jsonb_build_object('redemption_id', v_redemption_id, 'customer_id', v_customer.id,
                       'reward', v_program.reward_description, 'stamps', v_card.stamps_count));

  RETURN jsonb_build_object(
    'success', true,
    'redemption_id', v_redemption_id,
    'customer_name', v_customer.full_name,
    'reward', v_program.reward_description,
    'message', 'Premio canjeado correctamente'
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- 6. Tarjeta pública del cliente: agrega regla y premios intermedios.
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

  RETURN jsonb_build_object(
    'business_name',   v_business.name,
    'business_logo',   v_business.logo_url,
    'business_phone',  v_business.phone,
    'customer_name',   split_part(trim(v_customer.full_name), ' ', 1),
    'member_since',    v_customer.created_at,
    'has_card',        v_card.id IS NOT NULL,
    'program_name',    v_program.name,
    'stamp_rule',      v_program.stamp_rule,
    'stamps_count',    coalesce(v_card.stamps_count, 0),
    'stamps_required', v_program.stamps_required,
    'reward',          v_program.reward_description,
    'completed',       coalesce(v_card.stamps_count >= v_program.stamps_required, false),
    'milestones', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'stamps_at', m.stamps_at,
               'reward', m.reward_description,
               'reached', coalesce(v_card.stamps_count, 0) >= m.stamps_at,
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

-- ---------------------------------------------------------------------
-- 7. Permisos
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.save_loyalty_program_v2(uuid,text,integer,text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_loyalty_program_v2(uuid,text,integer,text,text,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.add_stamps(uuid,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_stamps(uuid,text,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.add_stamp(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_stamp(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.redeem_milestone(uuid,uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redeem_milestone(uuid,uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.redeem_loyalty_reward(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redeem_loyalty_reward(uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_card(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_card(text) TO anon, authenticated;

COMMIT;

-- Comprobación (debe devolver 4 filas):
SELECT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('save_loyalty_program_v2','add_stamps','redeem_milestone','get_public_card')
ORDER BY 1;
