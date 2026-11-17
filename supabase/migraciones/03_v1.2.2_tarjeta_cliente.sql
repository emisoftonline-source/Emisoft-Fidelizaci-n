-- =====================================================================
-- EMISOFT FIDELIZACIÓN DIGITAL · MIGRACIÓN 1.2.2 · TARJETA DEL CLIENTE
-- Ejecutar completo en Supabase > SQL Editor (después de la 1.2).
--
-- Agrega una función de SOLO LECTURA para que el cliente vea su tarjeta
-- al escanear su QR. El código QR (48 caracteres aleatorios) funciona
-- como llave: sin él no se puede consultar ninguna tarjeta.
-- No se muestra el celular ni el apellido del cliente.
-- No borra ni modifica datos. Se puede ejecutar más de una vez.
-- =====================================================================

BEGIN;

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

  SELECT * INTO v_card
  FROM public.loyalty_cards
  WHERE customer_id = v_customer.id AND business_id = v_customer.business_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_card.id IS NOT NULL THEN
    SELECT * INTO v_program FROM public.loyalty_programs WHERE id = v_card.program_id;
    -- Sellos del ciclo actual: los posteriores al último canje de esta tarjeta.
    SELECT max(redeemed_at) INTO v_since
    FROM public.loyalty_redemptions WHERE card_id = v_card.id;
  END IF;

  RETURN jsonb_build_object(
    'business_name',   v_business.name,
    'business_logo',   v_business.logo_url,
    'business_phone',  v_business.phone,
    'customer_name',   split_part(trim(v_customer.full_name), ' ', 1),
    'member_since',    v_customer.created_at,
    'has_card',        v_card.id IS NOT NULL,
    'program_name',    v_program.name,
    'stamps_count',    coalesce(v_card.stamps_count, 0),
    'stamps_required', v_program.stamps_required,
    'reward',          v_program.reward_description,
    'completed',       coalesce(v_card.stamps_count >= v_program.stamps_required, false),
    'recent_stamps', coalesce((
      SELECT jsonb_agg(s.created_at ORDER BY s.created_at DESC)
      FROM (
        SELECT created_at FROM public.stamps
        WHERE card_id = v_card.id
          AND created_at > coalesce(v_since, '-infinity'::timestamptz)
        ORDER BY created_at DESC
        LIMIT 50
      ) s
    ), '[]'::jsonb),
    'redemptions', coalesce((
      SELECT jsonb_agg(jsonb_build_object('date', r.redeemed_at, 'reward', r.reward_description)
                       ORDER BY r.redeemed_at DESC)
      FROM (
        SELECT redeemed_at, reward_description FROM public.loyalty_redemptions
        WHERE customer_id = v_customer.id
        ORDER BY redeemed_at DESC
        LIMIT 20
      ) r
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_card(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_card(text) TO anon, authenticated;

COMMIT;

-- Comprobación (debe devolver 1 fila: get_public_card):
SELECT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'get_public_card';
