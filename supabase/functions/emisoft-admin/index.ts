// EMISOFT Fidelización Digital 1.2 · Edge Function "emisoft-admin"
//
// Operaciones que necesitan la clave service_role (solo existe aquí, en el
// servidor de Supabase; nunca en el navegador):
//   - create_user:    crea el usuario de un negocio y su membresía.
//   - reset_password: restablece la contraseña de un usuario de negocio.
//
// Solo un usuario con profiles.role = 'superadmin' puede usar esta función.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BUSINESS_ROLES = ["admin_negocio", "vendedor"];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// Clave secreta del servidor: sistema nuevo (sb_secret_…) o clave service_role antigua.
function getSecretKey(): string | undefined {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const keys = JSON.parse(raw);
      const k = typeof keys === "string" ? keys : keys.default ?? Object.values(keys)[0];
      if (typeof k === "string" && k) return k;
    } catch {
      if (raw.startsWith("sb_secret_")) return raw;
    }
  }
  return Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
}

function validPassword(pw: unknown): pw is string {
  return typeof pw === "string" && pw.length >= 8 && pw.length <= 72;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = getSecretKey();
  if (!url || !serviceKey) {
    return json({ error: "Configuración del servidor incompleta" }, 500);
  }

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1. Identificar a quien llama a partir de su sesión.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Sesión requerida" }, 401);

  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const caller = authData?.user;
  if (authError || !caller) {
    return json({ error: "Sesión no válida. Vuelve a ingresar." }, 401);
  }

  // 2. Solo superadmin.
  const { data: callerProfile } = await admin
    .from("profiles").select("role").eq("id", caller.id).maybeSingle();
  if (callerProfile?.role !== "superadmin") {
    return json({ error: "Solo el superadministrador puede realizar esta acción" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Solicitud no válida" }, 400);
  }

  try {
    switch (body.action) {
      case "create_user":
        return await createUser(admin, caller.id, body);
      case "reset_password":
        return await resetPassword(admin, caller.id, body);
      default:
        return json({ error: "Acción no reconocida" }, 400);
    }
  } catch (e) {
    console.error(e);
    return json({ error: "Error interno del servidor" }, 500);
  }
});

async function createUser(
  admin: SupabaseClient,
  actorId: string,
  body: Record<string, unknown>,
): Promise<Response> {
  const email = String(body.email ?? "").trim().toLowerCase();
  const fullName = String(body.full_name ?? "").trim();
  const password = body.password;
  const role = String(body.role ?? "");
  const businessId = String(body.business_id ?? "");

  if (!EMAIL_RE.test(email)) return json({ error: "Correo electrónico no válido" }, 400);
  if (fullName.length < 2) return json({ error: "El nombre es obligatorio" }, 400);
  if (!validPassword(password)) {
    return json({ error: "La contraseña debe tener entre 8 y 72 caracteres" }, 400);
  }
  if (!BUSINESS_ROLES.includes(role)) return json({ error: "Rol no válido" }, 400);

  const { data: biz } = await admin
    .from("businesses").select("id,name").eq("id", businessId).maybeSingle();
  if (!biz) return json({ error: "Negocio no encontrado" }, 404);

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: fullName },
  });
  if (createError || !created?.user) {
    const msg = String(createError?.message ?? "");
    if (/already|registered|exists/i.test(msg)) {
      return json({ error: "Ese correo ya está registrado" }, 409);
    }
    return json({ error: "No se pudo crear el usuario: " + msg }, 400);
  }
  const userId = created.user.id;

  // El trigger handle_new_auth_user crea el perfil; aquí se fija nombre y rol.
  const { error: profileError } = await admin
    .from("profiles")
    .upsert({ id: userId, full_name: fullName, role }, { onConflict: "id" });

  const { data: membership, error: memberError } = profileError
    ? { data: null, error: profileError }
    : await admin
      .from("memberships")
      .insert({ user_id: userId, business_id: businessId, role, active: true })
      .select("id")
      .single();

  if (profileError || memberError) {
    // Deshacer: no dejar usuarios sin negocio.
    await admin.auth.admin.deleteUser(userId);
    console.error(profileError ?? memberError);
    return json({ error: "No se pudo asignar el usuario al negocio" }, 500);
  }

  await admin.from("audit_log").insert({
    business_id: businessId,
    actor_id: actorId,
    action: "member_created",
    entity_type: "membership",
    entity_id: membership.id,
    details: { user_id: userId, email, role },
  });

  return json({ success: true, user_id: userId, membership_id: membership.id });
}

async function resetPassword(
  admin: SupabaseClient,
  actorId: string,
  body: Record<string, unknown>,
): Promise<Response> {
  const userId = String(body.user_id ?? "");
  const password = body.new_password;

  if (!validPassword(password)) {
    return json({ error: "La contraseña debe tener entre 8 y 72 caracteres" }, 400);
  }

  const { data: target } = await admin
    .from("profiles").select("id,role").eq("id", userId).maybeSingle();
  if (!target) return json({ error: "Usuario no encontrado" }, 404);
  if (target.role === "superadmin") {
    return json({
      error: "La contraseña del superadministrador solo se cambia desde el panel de Supabase",
    }, 403);
  }

  const { error } = await admin.auth.admin.updateUserById(userId, { password });
  if (error) return json({ error: "No se pudo cambiar la contraseña: " + error.message }, 400);

  // Registrar en la auditoría de cada negocio del usuario (nunca la contraseña).
  const { data: memberships } = await admin
    .from("memberships").select("id,business_id").eq("user_id", userId);
  if (memberships?.length) {
    await admin.from("audit_log").insert(memberships.map((m) => ({
      business_id: m.business_id,
      actor_id: actorId,
      action: "password_reset",
      entity_type: "membership",
      entity_id: m.id,
      details: { user_id: userId },
    })));
  }

  return json({ success: true });
}
