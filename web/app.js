// EMISOFT Fidelización Digital · v1.3.2
const $ = id => document.getElementById(id);
const LOGO_BUCKET = 'business-logos';
const STORAGE_KEY = 'emisoft_business_id';
const ROLE_LABELS = {superadmin:'Superadministrador', admin_negocio:'Administrador', vendedor:'Cajero / Vendedor'};
const AUDIT_LABELS = {
  customer_card_created:'Cliente registrado', stamp_added:'Sello registrado',
  reward_redeemed:'Premio canjeado', loyalty_program_created:'Programa actualizado',
  business_created:'Negocio creado', business_updated:'Negocio editado',
  business_activated:'Negocio activado', business_suspended:'Negocio suspendido',
  member_created:'Usuario creado', member_activated:'Usuario activado',
  member_deactivated:'Usuario desactivado', password_reset:'Contraseña restablecida',
  milestone_redeemed:'Premio intermedio canjeado'
};

let sb, scanner = null, activeScanner = false;
let currentUser = null, isSuper = false;
let currentBusiness = null, currentRole = null;   // negocio y rol con el que se opera
let myBusinesses = [];                             // [{business, role}]
let customersCache = [], programsCache = [], milestonesCache = [], staffNames = {};
let allBusinesses = [], editingBusiness = null, usersBusiness = null, membersCache = [];

// ---------- utilidades ----------
function message(id, text, error = false) {
  const el = $(id);
  if (!el) return;
  el.textContent = text;
  el.classList.toggle('error', error);
}
function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function safeUrl(u) { return typeof u === 'string' && /^https:\/\//i.test(u) ? u : ''; }
function configReady() {
  return window.EMISOFT_SUPABASE_URL && !window.EMISOFT_SUPABASE_URL.includes('TU-PROYECTO')
    && window.EMISOFT_SUPABASE_ANON_KEY && !window.EMISOFT_SUPABASE_ANON_KEY.includes('TU_CLAVE');
}
function isAdmin() { return isSuper || currentRole === 'admin_negocio'; }
function randomPassword(len = 12) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const bytes = crypto.getRandomValues(new Uint32Array(len));
  return Array.from(bytes, b => chars[b % chars.length]).join('');
}
async function callAdmin(body) {
  const {data, error} = await sb.functions.invoke('emisoft-admin', {body});
  if (error) {
    let msg = error.message, status = error.context?.status;
    try { const j = await error.context?.clone().json(); if (j?.error) msg = j.error; else if (j?.message) msg = j.message; } catch (_) {}
    if (error.name === 'FunctionsFetchError' || error.name === 'FunctionsRelayError' || status === 404) {
      msg = 'No se pudo contactar la función "emisoft-admin". Verifica en Supabase > Edge Functions que esté desplegada con ese nombre exacto. (' + msg + ')';
    } else if (status === 401 && /jwt/i.test(msg)) {
      msg = 'La función rechazó la sesión (Invalid JWT). En Supabase > Edge Functions > emisoft-admin > Details, desactiva "Verify JWT" y vuelve a intentar.';
    }
    throw new Error(msg);
  }
  if (data?.error) throw new Error(data.error);
  return data;
}

// ---------- sesión ----------
async function init() {
  if (!configReady()) return message('loginMsg', 'Primero configura la URL y la clave pública en config.js', true);
  if (!window.supabase?.createClient) return message('loginMsg', 'No se pudo cargar la librería de Supabase. Revisa tu conexión a internet.', true);
  sb = window.supabase.createClient(window.EMISOFT_SUPABASE_URL, window.EMISOFT_SUPABASE_ANON_KEY);
  const {data: {session}, error} = await sb.auth.getSession();
  if (error) return message('loginMsg', error.message, true);
  if (session) await enterApp();
}
async function login() {
  message('loginMsg', 'Validando acceso...');
  $('loginBtn').disabled = true;
  const {error} = await sb.auth.signInWithPassword({email: $('email').value.trim(), password: $('password').value});
  $('loginBtn').disabled = false;
  if (error) return message('loginMsg', error.message === 'Invalid login credentials' ? 'Correo o contraseña incorrectos.' : error.message, true);
  await enterApp();
}
async function logout() {
  await stopScanner(false);
  await sb.auth.signOut();
  location.reload();
}

async function enterApp() {
  const {data: {user}, error: ue} = await sb.auth.getUser();
  if (ue || !user) { await sb.auth.signOut(); return message('loginMsg', 'La sesión expiró. Vuelve a ingresar.', true); }
  currentUser = user;

  $('login').classList.add('hidden');
  $('app').classList.remove('hidden');
  $('logout').classList.remove('hidden');

  const {data: profile, error: pe} = await sb.from('profiles').select('role,full_name').eq('id', user.id).single();
  if (pe) return message('appMsg', 'No se pudo leer el perfil: ' + pe.message, true);
  isSuper = profile.role === 'superadmin';
  $('userInfo').textContent = (profile.full_name ? profile.full_name + ' · ' : '') + (user.email || '');
  document.querySelectorAll('.super-only').forEach(el => el.classList.toggle('hidden', !isSuper));

  if (isSuper) {
    await loadAllBusinesses();
    myBusinesses = allBusinesses.map(b => ({business: b, role: 'superadmin'}));
    if (!myBusinesses.length) {
      setBusiness(null);
      showTab('businesses');
      return message('appMsg', 'Todavía no hay negocios. Crea el primero en la pestaña Negocios.');
    }
  } else {
    const {data, error} = await sb.from('memberships')
      .select('role,business_id,businesses(id,name,slug,logo_url,status,category)')
      .eq('user_id', user.id).eq('active', true);
    if (error) return message('appMsg', 'No se pudo leer tu negocio: ' + error.message, true);
    // Si el negocio está suspendido, la política RLS no devuelve sus datos.
    myBusinesses = (data || []).filter(m => m.businesses).map(m => ({business: m.businesses, role: m.role}));
    if (!myBusinesses.length) {
      setBusiness(null);
      document.querySelector('nav').classList.add('hidden');
      document.querySelectorAll('.tab-panel').forEach(p => p.classList.add('hidden'));
      return message('appMsg', (data || []).length
        ? 'Tu negocio está suspendido. Comunícate con EMISOFT.'
        : 'Tu usuario aún no tiene un negocio asignado. Comunícate con EMISOFT.', true);
    }
  }

  renderBusinessPicker();
  const saved = localStorage.getItem(STORAGE_KEY);
  const pick = myBusinesses.find(m => m.business.id === saved) || myBusinesses[0];
  await selectBusiness(pick.business.id);
}

function renderBusinessPicker() {
  const show = myBusinesses.length > 1 || isSuper;
  $('businessPickerWrap').classList.toggle('hidden', !show);
  $('businessPicker').innerHTML = myBusinesses.map(m =>
    `<option value="${escapeHtml(m.business.id)}">${escapeHtml(m.business.name)}${m.business.status === 'suspended' ? ' (suspendido)' : ''}</option>`
  ).join('');
  if (currentBusiness) $('businessPicker').value = currentBusiness.id;
}

function setBusiness(biz, role = null) {
  currentBusiness = biz;
  currentRole = role;
  $('businessName').textContent = biz ? biz.name : (isSuper ? 'Superadministrador EMISOFT' : 'Sin negocio');
  $('roleLabel').textContent = (ROLE_LABELS[isSuper ? 'superadmin' : role] || 'Panel').toUpperCase() + ' · PANEL DE FIDELIZACIÓN';
  const logo = safeUrl(biz?.logo_url);
  $('businessLogo').classList.toggle('hidden', !logo);
  if (logo) { $('businessLogo').src = logo; $('businessLogo').alt = 'Logo de ' + biz.name; }
  const suspended = biz?.status === 'suspended';
  $('suspendedNotice').classList.toggle('hidden', !suspended);
  $('statusPill').textContent = suspended ? 'SUSPENDIDO' : 'EN LÍNEA';
  $('statusPill').classList.toggle('pill-off', suspended);
  document.querySelectorAll('.admin-only').forEach(el => el.classList.toggle('hidden', !isAdmin()));
}

async function selectBusiness(id) {
  const m = myBusinesses.find(x => x.business.id === id);
  if (!m) return;
  await stopScanner(false);
  setBusiness(m.business, m.role);
  localStorage.setItem(STORAGE_KEY, id);
  $('businessPicker').value = id;
  $('newCard').classList.add('hidden');
  ['customerMsg', 'scanMsg', 'settingsMsg', 'historyMsg', 'auditMsg', 'appMsg'].forEach(x => message(x, ''));
  $('historyRows').innerHTML = '<tr><td colspan="6">Selecciona esta pestaña para cargar el historial.</td></tr>';
  $('auditRows').innerHTML = '<tr><td colspan="4">Selecciona esta pestaña para cargar la auditoría.</td></tr>';
  const active = document.querySelector('.tab.active')?.dataset.tab;
  if (!isAdmin() && ['settings', 'audit'].includes(active)) showTab('customers');
  await Promise.all([loadPrograms(), loadCustomers(), loadStaffNames()]);
  if (isSuper) { renderBusinesses(); openUsers(id, false); }
  if (active === 'history') loadHistory();
  if (active === 'audit') loadAudit();
}

async function loadStaffNames() {
  staffNames = {};
  if (!currentBusiness) return;
  const {data} = await sb.rpc('list_business_members', {p_business_id: currentBusiness.id});
  (data || []).forEach(m => staffNames[m.user_id] = m.full_name || m.email || 'Usuario');
  staffNames[currentUser.id] = staffNames[currentUser.id] || (isSuper ? 'Superadministrador' : 'Tú');
}
function staffName(id) { return staffNames[id] || (id ? 'Usuario ' + String(id).slice(0, 8) : '—'); }

// ---------- programas / política ----------
const CATEGORIES = ['Restaurante', 'Pollería', 'Pizzería', 'Cafetería', 'Heladería', 'Panadería / Pastelería',
  'Peluquería / Barbería', 'Salón de belleza / Spa', 'Tienda / Minimarket', 'Farmacia', 'Lavandería',
  'Gimnasio', 'Veterinaria', 'Ferretería', 'Otro'];
const ICONS = ['🎁', '🎉', '⭐', '💸', '🏷️', '🔥', '❤️', '🏆', '🍽️', '🍗', '🍔', '🍕', '☕', '🥤', '🍦', '🍰', '✂️', '💈', '💅', '💆', '🛒', '💊', '🧺', '🏋️', '🐾'];
const TEMPLATES = {
  'Restaurante':  {name: 'Cliente frecuente', rule: '1 sello por cada compra, sin importar cuántos productos lleve', required: 10, reward: 'Plato principal gratis',
                   milestones: [{stamps_at: 3, reward: 'Postre gratis', icon: '🎁', surprise: true}, {stamps_at: 7, reward: '15% de descuento en tu cuenta', icon: '💸'}]},
  'Pollería':     {name: 'Cliente frecuente', rule: '1 sello por cada 2 cuartos de pollo', required: 10, reward: 'Un pollo entero gratis',
                   milestones: [{stamps_at: 5, reward: 'Una gaseosa gratis', icon: '🥤'}]},
  'Pizzería':     {name: 'Club pizza', rule: '1 sello por cada pizza mediana o grande', required: 8, reward: 'Pizza mediana gratis',
                   milestones: [{stamps_at: 4, reward: 'Porción de pan al ajo', icon: '🎁', surprise: true}]},
  'Cafetería':    {name: 'Club del café', rule: '1 sello por cada café', required: 8, reward: 'Un café gratis',
                   milestones: [{stamps_at: 4, reward: 'Galleta gratis', icon: '🍰'}]},
  'Heladería':    {name: 'Club helado', rule: '1 sello por cada compra', required: 8, reward: 'Helado doble gratis',
                   milestones: [{stamps_at: 4, reward: 'Topping gratis', icon: '🍦'}]},
  'Panadería / Pastelería': {name: 'Cliente frecuente', rule: '1 sello por cada compra desde Bs 20', required: 10, reward: 'Torta individual gratis',
                   milestones: [{stamps_at: 5, reward: 'Sorpresa dulce', icon: '🎁', surprise: true}]},
  'Peluquería / Barbería': {name: 'Cliente frecuente', rule: '1 sello por cada corte', required: 10, reward: 'Corte gratis',
                   milestones: [{stamps_at: 5, reward: '50% de descuento en tu corte', icon: '✂️'}]},
  'Salón de belleza / Spa': {name: 'Club belleza', rule: '1 sello por cada servicio', required: 8, reward: 'Manicure gratis',
                   milestones: [{stamps_at: 3, reward: 'Hidratación gratis', icon: '🎁', surprise: true}, {stamps_at: 6, reward: '20% de descuento', icon: '💸'}]},
  'Tienda / Minimarket': {name: 'Cliente frecuente', rule: '1 sello por cada compra desde Bs 50', required: 10, reward: 'Vale de Bs 30 en compras',
                   milestones: [{stamps_at: 5, reward: 'Producto sorpresa', icon: '🎁', surprise: true}]},
  'Farmacia':     {name: 'Cliente frecuente', rule: '1 sello por cada compra desde Bs 50', required: 10, reward: '15% de descuento en tu compra',
                   milestones: [{stamps_at: 5, reward: '5% de descuento', icon: '💊'}]},
  'Lavandería':   {name: 'Cliente frecuente', rule: '1 sello por cada servicio de lavado', required: 10, reward: 'Un lavado gratis',
                   milestones: [{stamps_at: 5, reward: 'Planchado gratis de 3 prendas', icon: '🧺'}]},
  'Gimnasio':     {name: 'Club fitness', rule: '1 sello por cada mes pagado', required: 6, reward: 'Un mes gratis',
                   milestones: [{stamps_at: 3, reward: 'Clase personalizada gratis', icon: '🏋️'}]},
  'Veterinaria':  {name: 'Cliente frecuente', rule: '1 sello por cada consulta o baño', required: 8, reward: 'Baño gratis para tu mascota',
                   milestones: [{stamps_at: 4, reward: 'Snack para tu mascota', icon: '🐾'}]},
  'Ferretería':   {name: 'Cliente frecuente', rule: '1 sello por cada compra desde Bs 100', required: 10, reward: 'Vale de Bs 50',
                   milestones: [{stamps_at: 5, reward: '5% de descuento', icon: '🏷️'}]},
  'Otro':         {name: 'Cliente frecuente', rule: '1 sello por cada compra', required: 10, reward: 'Premio por completar la tarjeta',
                   milestones: [{stamps_at: 3, reward: 'Sorpresa', icon: '🎁', surprise: true}, {stamps_at: 7, reward: '10% de descuento', icon: '💸'}]}
};
function renderTemplateButtons() {
  const cat = currentBusiness?.category;
  const names = Object.keys(TEMPLATES).sort((a, b) => (b === cat) - (a === cat));
  $('templateButtons').innerHTML = names.map(n =>
    `<button type="button" class="${n === cat ? '' : 'ghost'} small-action" data-template="${escapeHtml(n)}">${escapeHtml(n)}</button>`).join('');
}
function msIcon(m) { return m.icon || (m.is_surprise ? '🎁' : '⭐'); }
function programMilestones(programId) {
  return milestonesCache.filter(m => m.program_id === programId).sort((a, b) => a.stamps_at - b.stamps_at);
}
function describeProgram(p) {
  if (!p) return '';
  const ms = programMilestones(p.id);
  return `<p><strong>${escapeHtml(p.name)}</strong></p>
    ${p.stamp_rule ? `<p>Cómo se gana: <strong>${escapeHtml(p.stamp_rule)}</strong></p>` : ''}
    <ul class="policy-list">
      ${ms.map(m => `<li><span class="badge gift">${escapeHtml(msIcon(m))} Sello ${m.stamps_at}</span> ${escapeHtml(m.reward_description)}${m.is_surprise ? ' <span class="muted">(sorpresa: el cliente no lo ve hasta llegar)</span>' : ''}</li>`).join('')}
      <li><span class="badge ok">Sello ${p.stamps_required}</span> ${escapeHtml(p.reward_description)} <span class="muted">(premio final, reinicia la tarjeta)</span></li>
    </ul>`;
}
function milestoneRow(m = {}) {
  const div = document.createElement('div');
  div.className = 'milestone-row';
  div.innerHTML = `<label>Al llegar al sello<input type="number" class="ms-at" min="1" max="999" step="1" placeholder="Ej. 3"></label>
    <label>Ícono<select class="ms-icon">${ICONS.map(i => `<option>${i}</option>`).join('')}</select></label>
    <label>Premio<input class="ms-reward" maxlength="300" placeholder="Ej. Postre gratis"></label>
    <label class="inline ms-surprise-wrap"><input type="checkbox" class="ms-surprise"> Sorpresa</label>
    <button type="button" class="ghost small-action ms-remove" title="Quitar">Quitar</button>`;
  div.querySelector('.ms-at').value = m.stamps_at ?? '';
  div.querySelector('.ms-reward').value = m.reward ?? m.reward_description ?? '';
  const icon = m.icon || ((m.surprise ?? m.is_surprise) ? '🎁' : '🎁');
  if (!ICONS.includes(icon)) div.querySelector('.ms-icon').insertAdjacentHTML('afterbegin', `<option>${escapeHtml(icon)}</option>`);
  div.querySelector('.ms-icon').value = icon;
  div.querySelector('.ms-surprise').checked = !!(m.surprise ?? m.is_surprise);
  return div;
}
function setMilestoneRows(list) {
  $('milestoneRows').innerHTML = '';
  (list || []).forEach(m => $('milestoneRows').appendChild(milestoneRow(m)));
}
function fillProgramForm(p) {
  $('programName').value = p?.name || '';
  $('stampRule').value = p?.stamp_rule || p?.rule || '';
  $('stampsRequired').value = p?.stamps_required || p?.required || '';
  $('rewardDescription').value = p?.reward_description || p?.reward || '';
  setMilestoneRows(p?.milestones || (p?.id ? programMilestones(p.id) : []));
}
async function loadPrograms() {
  programsCache = []; milestonesCache = [];
  if (!currentBusiness) return;
  const [pr, ms] = await Promise.all([
    sb.from('loyalty_programs')
      .select('id,name,stamps_required,reward_description,stamp_rule,active,created_at')
      .eq('business_id', currentBusiness.id).order('created_at', {ascending: false}),
    sb.from('loyalty_milestones')
      .select('id,program_id,stamps_at,reward_description,icon,is_surprise')
      .eq('business_id', currentBusiness.id)
  ]);
  if (pr.error) return message('settingsMsg', 'No se pudieron cargar los programas: ' + pr.error.message, true);
  programsCache = pr.data || [];
  milestonesCache = ms.data || [];
  const active = programsCache.find(p => p.active);
  $('activeProgram').innerHTML = active ? describeProgram(active) : '<p>Este negocio todavía no tiene un programa activo.</p>';
  fillProgramForm(active);
  renderTemplateButtons();
  $('scanRule').classList.toggle('hidden', !active?.stamp_rule);
  $('scanRule').textContent = active?.stamp_rule ? 'Regla del negocio: ' + active.stamp_rule : '';
  renderCustomers();   // la tabla depende de los programas y premios
}
async function saveProgram() {
  if (!isAdmin()) return message('settingsMsg', 'Tu usuario no tiene permiso para configurar la fidelización.', true);
  const name = $('programName').value.trim();
  const rule = $('stampRule').value.trim();
  const required = Number($('stampsRequired').value);
  const reward = $('rewardDescription').value.trim();
  if (name.length < 2) return message('settingsMsg', 'Escribe un nombre para el programa.', true);
  if (!Number.isInteger(required) || required < 1 || required > 1000) return message('settingsMsg', 'La cantidad de sellos debe ser un número entre 1 y 1000.', true);
  if (reward.length < 2) return message('settingsMsg', 'Describe el premio final.', true);
  const milestones = [];
  for (const row of $('milestoneRows').children) {
    const at = row.querySelector('.ms-at').value.trim(), rw = row.querySelector('.ms-reward').value.trim();
    if (!at && !rw) continue;
    const n = Number(at);
    if (!Number.isInteger(n) || n < 1 || n >= required) return message('settingsMsg', `Los premios intermedios deben estar entre el sello 1 y el ${required - 1}.`, true);
    if (rw.length < 2) return message('settingsMsg', `Describe el premio del sello ${n}.`, true);
    if (milestones.some(m => m.stamps_at === n)) return message('settingsMsg', `Hay dos premios en el sello ${n}.`, true);
    milestones.push({stamps_at: n, reward: rw, icon: row.querySelector('.ms-icon').value, surprise: row.querySelector('.ms-surprise').checked});
  }
  milestones.sort((a, b) => a.stamps_at - b.stamps_at);
  const resumen = [rule && `Regla: ${rule}`, ...milestones.map(m => `${m.icon} Sello ${m.stamps_at}: ${m.reward}${m.surprise ? ' (sorpresa)' : ''}`), `Sello ${required}: ${reward} (final)`].filter(Boolean).join('\n');
  if (!confirm(`Se guardará esta política:\n\n${resumen}\n\nLas tarjetas en curso terminan su ciclo con la política anterior. ¿Continuar?`)) return;
  $('saveProgram').disabled = true;
  message('settingsMsg', 'Guardando política...');
  const {error} = await sb.rpc('save_loyalty_program_v2', {
    p_business_id: currentBusiness.id, p_name: name, p_stamps_required: required,
    p_reward_description: reward, p_stamp_rule: rule, p_milestones: milestones
  });
  $('saveProgram').disabled = false;
  if (error) return message('settingsMsg', 'No se pudo guardar: ' + error.message, true);
  message('settingsMsg', 'Nueva política guardada correctamente.');
  await Promise.all([loadPrograms(), loadCustomers()]);
}

// ---------- clientes ----------
async function createCustomer() {
  if (!currentBusiness) return message('customerMsg', 'No hay negocio seleccionado.', true);
  const name = $('customerName').value.trim(), phone = $('customerPhone').value.trim();
  if (name.length < 2 || phone.length < 6) return message('customerMsg', 'Ingresa nombre completo y un celular válido.', true);
  $('createCustomer').disabled = true;
  message('customerMsg', 'Registrando cliente...');
  const {data, error} = await sb.rpc('create_customer_card', {p_business_id: currentBusiness.id, p_full_name: name, p_phone: phone});
  $('createCustomer').disabled = false;
  if (error) return message('customerMsg', error.message, true);
  const result = Array.isArray(data) ? data[0] : data;
  if (!result?.qr_token) return message('customerMsg', 'El cliente se creó, pero no se recibió el código QR.', true);
  showQr('Tarjeta creada', name, phone, result.qr_token);
  $('customerName').value = '';
  $('customerPhone').value = '';
  message('customerMsg', 'Cliente registrado correctamente.');
  await loadCustomers();
}
// Enlace de la tarjeta del cliente. El QR contiene este enlace.
function cardUrl(token) { return new URL('tarjeta.html?t=' + encodeURIComponent(token), location.href).href; }
// Acepta el QR nuevo (enlace) y el antiguo (solo el código).
function tokenFromScan(text) {
  const raw = String(text || '').trim();
  try { const t = new URL(raw).searchParams.get('t'); if (t) return t.trim().toLowerCase(); } catch (_) {}
  return raw.toLowerCase();
}
function whatsappUrl(phone, text) {
  let digits = String(phone || '').replace(/\D/g, '');
  if (digits.length === 8) digits = '591' + digits;   // celular boliviano sin código de país
  return 'https://wa.me/' + digits + '?text=' + encodeURIComponent(text);
}
function showQr(title, name, phone, token) {
  const url = cardUrl(token);
  $('newCard').classList.remove('hidden');
  $('newCardTitle').textContent = title;
  $('newCardText').textContent = name + ' · ' + phone;
  $('qrOutput').innerHTML = '';
  $('qrOutput').dataset.name = name;
  new QRCode($('qrOutput'), {text: url, width: 220, height: 220, correctLevel: QRCode.CorrectLevel.M});
  $('openCard').href = url;
  $('sendWhatsapp').href = whatsappUrl(phone,
    `Hola ${name.split(' ')[0]}, esta es tu tarjeta de fidelización de ${currentBusiness?.name || 'nuestro negocio'}. ` +
    `Ábrela para ver tus sellos y muéstrala en caja en cada compra: ${url}`);
  $('newCard').scrollIntoView({behavior: 'smooth', block: 'center'});
}
function stampResultText(data) {
  let t = `✔ ${data.quantity > 1 ? data.quantity + ' sellos registrados' : 'Sello registrado'}. ${data.customer_name}: ${data.stamps_count} de ${data.stamps_required} sellos.`;
  (data.unlocked || []).forEach(u => t += ` 🎁 ¡Desbloqueó "${u.reward}" (sello ${u.stamps_at})! Canjéalo en Clientes.`);
  if (data.completed) t += ' 🏆 ¡Tarjeta completada! Ya puede canjear el premio final en Clientes.';
  return t;
}
async function addStamps(token, qty) {
  return sb.rpc('add_stamps', {p_business_id: currentBusiness.id, p_qr_token: token, p_quantity: qty});
}
async function addStampManual(customerId) {
  const c = customersCache.find(x => x.id === customerId);
  if (!c || !currentBusiness) return;
  const active = programsCache.find(p => p.active);
  const ans = prompt(`¿Cuántos sellos sumar a ${c.full_name}?` + (active?.stamp_rule ? `\nRegla: ${active.stamp_rule}` : ''), '1');
  if (ans === null) return;
  const qty = Number(ans);
  if (!Number.isInteger(qty) || qty < 1 || qty > 100) return message('customerMsg', 'Escribe una cantidad entre 1 y 100.', true);
  const {data, error} = await addStamps(c.qr_token, qty);
  if (error) return message('customerMsg', error.message, true);
  message('customerMsg', stampResultText(data));
  await loadCustomers();
}
function downloadQr() {
  const canvas = $('qrOutput').querySelector('canvas');
  const img = $('qrOutput').querySelector('img');
  const src = canvas ? canvas.toDataURL('image/png') : img?.src;
  if (!src) return;
  const a = document.createElement('a');
  a.href = src;
  a.download = 'QR-' + ($('qrOutput').dataset.name || 'cliente').replace(/[^\w\-]+/g, '_') + '.png';
  a.click();
}
async function loadCustomers() {
  customersCache = [];
  if (!currentBusiness) { renderCustomers(); return; }
  const {data, error} = await sb.from('customers')
    .select('id,full_name,phone,qr_token,created_at,loyalty_cards(id,stamps_count,program_id,completed_at,milestones_redeemed)')
    .eq('business_id', currentBusiness.id).order('created_at', {ascending: false}).limit(500);
  if (error) {
    $('customerRows').innerHTML = `<tr><td colspan="5">Error: ${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  customersCache = data || [];
  renderCustomers();
}
function renderCustomers() {
  const q = $('filter').value.toLowerCase();
  const rows = customersCache.filter(c => (c.full_name + ' ' + c.phone).toLowerCase().includes(q));
  $('customerRows').innerHTML = rows.map(c => {
    const qrBtn = `<button class="small-action secondary" data-show-qr="${escapeHtml(c.id)}">Ver tarjeta / QR</button>`;
    const cards = c.loyalty_cards || [];
    if (!cards.length) {
      return `<tr><td>${escapeHtml(c.full_name)}</td><td>${escapeHtml(c.phone)}</td><td>Sin tarjeta</td><td>—</td><td>${qrBtn}</td></tr>`;
    }
    return cards.map(card => {
      const program = programsCache.find(p => p.id === card.program_id);
      const required = Number(program?.stamps_required || 0);
      const count = Number(card.stamps_count || 0);
      const complete = required > 0 && count >= required;
      const progress = required ? `${count} / ${required}` : `${count} sellos`;
      const used = card.milestones_redeemed || [];
      const ms = program ? programMilestones(program.id) : [];
      const benefits = ms.map(m => {
        const st = used.includes(m.id) ? '<span class="ms-state done">canjeado</span>'
          : count >= m.stamps_at ? '<span class="ms-state ready">disponible</span>' : '';
        return `<div class="ms-line">${escapeHtml(msIcon(m))} Sello ${m.stamps_at}: ${escapeHtml(m.reward_description)}${m.is_surprise ? ' <span class="muted">(sorpresa)</span>' : ''} ${st}</div>`;
      }).join('') + `<div class="ms-line"><strong>Sello ${required || '?'}:</strong> ${escapeHtml(program?.reward_description || 'Programa no disponible')}</div>`;
      const msButtons = ms.filter(m => count >= m.stamps_at && !used.includes(m.id))
        .map(m => `<button class="small-action gift-btn" data-redeem-ms="${escapeHtml(m.id)}" data-card="${escapeHtml(card.id)}">${escapeHtml(msIcon(m))} Canjear: ${escapeHtml(m.reward_description)}</button>`).join('');
      const action = complete
        ? `<button class="small-action" data-redeem-card="${escapeHtml(card.id)}">Canjear premio final</button>`
        : `<button class="small-action" data-add-stamp="${escapeHtml(c.id)}">+ Sellos</button>`;
      return `<tr>
        <td>${escapeHtml(c.full_name)}</td>
        <td>${escapeHtml(c.phone)}</td>
        <td>${complete ? '<span class="status-complete">Completa</span>' : escapeHtml(progress)}</td>
        <td class="benefits">${benefits}</td>
        <td>${msButtons} ${action} ${qrBtn}</td>
      </tr>`;
    }).join('');
  }).join('') || `<tr><td colspan="5">${currentBusiness ? 'Todavía no hay clientes registrados.' : 'Selecciona un negocio.'}</td></tr>`;
}
async function redeemCard(cardId) {
  if (!currentBusiness) return;
  if (!confirm('¿Confirmas que entregaste el premio al cliente? Esta acción reiniciará la tarjeta para un nuevo ciclo y quedará registrada en el historial.')) return;
  const {data, error} = await sb.rpc('redeem_loyalty_reward', {p_business_id: currentBusiness.id, p_card_id: cardId});
  if (error) return message('customerMsg', 'No se pudo realizar el canje: ' + error.message, true);
  message('customerMsg', `${data.customer_name}: ${data.message}. Premio: ${data.reward}`);
  await loadCustomers();
}

async function redeemMilestone(cardId, milestoneId) {
  const m = milestonesCache.find(x => x.id === milestoneId);
  if (!confirm(`¿Confirmas que entregaste "${m?.reward_description || 'el premio'}"? La tarjeta NO se reinicia; el cliente sigue acumulando sellos.`)) return;
  const {data, error} = await sb.rpc('redeem_milestone', {p_business_id: currentBusiness.id, p_card_id: cardId, p_milestone_id: milestoneId});
  if (error) return message('customerMsg', 'No se pudo canjear: ' + error.message, true);
  message('customerMsg', `${data.customer_name}: ${data.message}. Premio: ${data.reward}`);
  await loadCustomers();
}

// ---------- historial y auditoría ----------
async function loadHistory() {
  if (!currentBusiness) return;
  message('historyMsg', 'Cargando historial...');
  const {data, error} = await sb.from('loyalty_redemptions')
    .select('id,customer_id,stamps_count,reward_description,redeemed_at,redeemed_by,milestone_id')
    .eq('business_id', currentBusiness.id).order('redeemed_at', {ascending: false}).limit(300);
  if (error) {
    $('historyRows').innerHTML = `<tr><td colspan="6">Error: ${escapeHtml(error.message)}</td></tr>`;
    return message('historyMsg', 'No se pudo cargar el historial: ' + error.message, true);
  }
  const names = {};
  customersCache.forEach(c => names[c.id] = c.full_name);
  const missing = [...new Set((data || []).map(r => r.customer_id).filter(id => !names[id]))];
  if (missing.length) {
    const {data: extra} = await sb.from('customers').select('id,full_name').in('id', missing);
    (extra || []).forEach(c => names[c.id] = c.full_name);
  }
  $('historyRows').innerHTML = (data || []).map(r => `<tr>
    <td>${escapeHtml(new Date(r.redeemed_at).toLocaleString())}</td>
    <td>${escapeHtml(names[r.customer_id] || 'Cliente')}</td>
    <td>${escapeHtml(r.reward_description)}</td>
    <td>${r.milestone_id ? '<span class="badge gift">Intermedio</span>' : '<span class="badge ok">Final</span>'}</td>
    <td>${escapeHtml(r.stamps_count)}</td>
    <td>${escapeHtml(staffName(r.redeemed_by))}</td>
  </tr>`).join('') || '<tr><td colspan="6">Todavía no hay premios canjeados.</td></tr>';
  message('historyMsg', `${(data || []).length} canje(s) encontrado(s).`);
}
function auditDetail(r) {
  const d = r.details || {};
  if (r.action === 'loyalty_program_created') return `${d.name}: ${d.stamps_required} sellos → ${d.reward_description}` +
    (d.stamp_rule ? ` · Regla: ${d.stamp_rule}` : '') + ((d.milestones || []).map(m => ` · Sello ${m.stamps_at}: ${m.reward}`).join(''));
  if (r.action === 'stamp_added') return `${d.quantity > 1 ? '+' + d.quantity + ' sellos · ' : ''}Total: ${d.stamps_count}`;
  if (r.action === 'milestone_redeemed') return `${d.reward} (sello ${d.stamps})`;
  if (r.action === 'reward_redeemed') return `${d.reward} (${d.stamps} sellos)`;
  if (r.action === 'member_created') return `${d.email} · ${ROLE_LABELS[d.role] || d.role}`;
  if (r.action === 'member_activated' || r.action === 'member_deactivated' || r.action === 'password_reset') return staffName(d.user_id);
  if (d.name) return d.name;
  return '';
}
async function loadAudit() {
  if (!currentBusiness || !isAdmin()) return;
  message('auditMsg', 'Cargando auditoría...');
  const {data, error} = await sb.from('audit_log')
    .select('created_at,action,actor_id,details')
    .eq('business_id', currentBusiness.id).order('created_at', {ascending: false}).limit(200);
  if (error) return message('auditMsg', 'No se pudo cargar la auditoría: ' + error.message, true);
  $('auditRows').innerHTML = (data || []).map(r => `<tr>
    <td>${escapeHtml(new Date(r.created_at).toLocaleString())}</td>
    <td>${escapeHtml(AUDIT_LABELS[r.action] || r.action)}</td>
    <td>${escapeHtml(auditDetail(r))}</td>
    <td>${escapeHtml(staffName(r.actor_id))}</td>
  </tr>`).join('') || '<tr><td colspan="4">Sin registros.</td></tr>';
  message('auditMsg', `${(data || []).length} registro(s).`);
}

// ---------- escáner ----------
async function startScanner() {
  if (activeScanner) return;
  if (!currentBusiness) return message('scanMsg', 'Selecciona un negocio.', true);
  if (!window.Html5Qrcode) return message('scanMsg', 'No se pudo cargar el lector QR.', true);
  scanner = scanner || new Html5Qrcode('reader');
  try {
    await scanner.start({facingMode: 'environment'}, {fps: 10, qrbox: {width: 230, height: 230}},
      async decodedText => {
        if (!currentBusiness || !activeScanner) return;
        await stopScanner(false);
        const qty = Number($('scanQty').value);
        if (!Number.isInteger(qty) || qty < 1 || qty > 100) return message('scanMsg', 'La cantidad de sellos debe estar entre 1 y 100.', true);
        const {data, error} = await addStamps(tokenFromScan(decodedText), qty);
        if (error) message('scanMsg', error.message, true);
        else message('scanMsg', stampResultText(data));
        $('scanQty').value = 1;
        $('startScan').textContent = 'Escanear siguiente cliente';
        await loadCustomers();
      }, () => {});
    activeScanner = true;
    message('scanMsg', 'Cámara activa. Enfoca el QR del cliente.');
  } catch (e) {
    message('scanMsg', 'No se pudo activar la cámara: ' + (e?.message || e), true);
  }
}
async function stopScanner(showMessage = true) {
  if (scanner && activeScanner) {
    try { await scanner.stop(); } catch (e) {}
    activeScanner = false;
  }
  if (showMessage) message('scanMsg', 'Escáner detenido.');
}

// ---------- superadmin: negocios ----------
async function loadAllBusinesses() {
  const {data, error} = await sb.from('businesses')
    .select('id,name,slug,phone,logo_url,status,category,created_at').order('name');
  if (error) {
    $('businessRows').innerHTML = `<tr><td colspan="6">Error: ${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  allBusinesses = data || [];
  renderBusinesses();
}
function renderBusinesses() {
  $('businessRows').innerHTML = allBusinesses.map(b => {
    const logo = safeUrl(b.logo_url);
    const active = b.status === 'active';
    return `<tr class="${currentBusiness?.id === b.id ? 'row-selected' : ''}">
      <td>${logo ? `<img class="biz-logo sm" src="${escapeHtml(logo)}" alt="">` : '<span class="muted">—</span>'}</td>
      <td><strong>${escapeHtml(b.name)}</strong><div class="muted small-text">${escapeHtml(b.category || 'Sin rubro')}</div></td>
      <td>${escapeHtml(b.slug)}</td>
      <td>${escapeHtml(b.phone || '—')}</td>
      <td><span class="badge ${active ? 'ok' : 'off'}">${active ? 'Activo' : 'Suspendido'}</span></td>
      <td>
        <button class="small-action" data-biz-open="${escapeHtml(b.id)}">Operar</button>
        <button class="small-action secondary" data-biz-policy="${escapeHtml(b.id)}">Política</button>
        <button class="small-action secondary" data-biz-users="${escapeHtml(b.id)}">Usuarios</button>
        <button class="small-action secondary" data-biz-edit="${escapeHtml(b.id)}">Editar</button>
        <button class="small-action ${active ? 'danger' : ''}" data-biz-status="${escapeHtml(b.id)}">${active ? 'Suspender' : 'Activar'}</button>
      </td>
    </tr>`;
  }).join('') || '<tr><td colspan="6">Todavía no hay negocios.</td></tr>';
}
function resetBusinessForm() {
  editingBusiness = null;
  ['bizName', 'bizSlug', 'bizPhone', 'bizLogo'].forEach(id => $(id).value = '');
  $('bizCategory').value = '';
  $('bizRemoveLogo').checked = false;
  $('bizRemoveLogoWrap').classList.add('hidden');
  $('bizLogoPreview').classList.add('hidden');
  $('bizFormTitle').textContent = 'Nuevo negocio';
  $('saveBusiness').textContent = 'Crear negocio';
  $('cancelBusinessEdit').classList.add('hidden');
}
function editBusiness(id) {
  const b = allBusinesses.find(x => x.id === id);
  if (!b) return;
  editingBusiness = b;
  $('bizName').value = b.name || '';
  $('bizSlug').value = b.slug || '';
  $('bizPhone').value = b.phone || '';
  $('bizCategory').value = b.category || '';
  $('bizLogo').value = '';
  $('bizRemoveLogo').checked = false;
  const logo = safeUrl(b.logo_url);
  $('bizRemoveLogoWrap').classList.toggle('hidden', !logo);
  $('bizLogoPreview').classList.toggle('hidden', !logo);
  if (logo) $('bizLogoPreview').src = logo;
  $('bizFormTitle').textContent = 'Editar: ' + b.name;
  $('saveBusiness').textContent = 'Guardar cambios';
  $('cancelBusinessEdit').classList.remove('hidden');
  message('bizMsg', '');
  $('bizFormTitle').scrollIntoView({behavior: 'smooth'});
}
function previewLogo() {
  const f = $('bizLogo').files[0];
  if (!f) return;
  $('bizLogoPreview').src = URL.createObjectURL(f);
  $('bizLogoPreview').classList.remove('hidden');
}
async function uploadLogo(businessId, file) {
  const ext = {'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp'}[file.type];
  const path = `${businessId}/logo-${Date.now()}.${ext}`;
  const {error} = await sb.storage.from(LOGO_BUCKET).upload(path, file, {contentType: file.type, cacheControl: '31536000'});
  if (error) throw new Error('No se pudo subir el logo: ' + error.message);
  return sb.storage.from(LOGO_BUCKET).getPublicUrl(path).data.publicUrl;
}
async function saveBusiness() {
  const name = $('bizName').value.trim();
  if (name.length < 2) return message('bizMsg', 'Escribe el nombre del negocio.', true);
  const file = $('bizLogo').files[0];
  if (file) {
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) return message('bizMsg', 'El logo debe ser PNG, JPG o WEBP.', true);
    if (file.size > 2 * 1024 * 1024) return message('bizMsg', 'El logo no debe superar 2 MB.', true);
  }
  $('saveBusiness').disabled = true;
  message('bizMsg', 'Guardando negocio...');
  try {
    const removeLogo = editingBusiness && $('bizRemoveLogo').checked && !file;
    const params = {
      p_business_id: editingBusiness?.id || null,
      p_name: name,
      p_slug: $('bizSlug').value.trim() || null,
      p_phone: $('bizPhone').value.trim(),
      p_logo_url: removeLogo ? '' : null
    };
    let {data: biz, error} = await sb.rpc('admin_save_business', params);
    if (error) throw error;
    if (file) {
      message('bizMsg', 'Subiendo logo...');
      const url = await uploadLogo(biz.id, file);
      ({data: biz, error} = await sb.rpc('admin_save_business', {
        p_business_id: biz.id, p_name: biz.name, p_slug: biz.slug, p_phone: biz.phone || '', p_logo_url: url
      }));
      if (error) throw error;
    }
    const category = $('bizCategory').value;
    if ((category || null) !== (biz.category || null)) {
      const {error: ce} = await sb.rpc('admin_set_business_category', {p_business_id: biz.id, p_category: category});
      if (ce) throw ce;
    }
    const wasNew = !editingBusiness;
    resetBusinessForm();
    await refreshBusinessesEverywhere();
    message('bizMsg', wasNew
      ? `Negocio "${biz.name}" creado con un programa inicial de 10 sellos. Ahora crea sus usuarios y configura su política con el botón "Política".`
      : `Negocio "${biz.name}" actualizado.`);
    if (wasNew) openUsers(biz.id);
  } catch (e) {
    message('bizMsg', e.message || String(e), true);
  } finally {
    $('saveBusiness').disabled = false;
  }
}
async function toggleBusinessStatus(id) {
  const b = allBusinesses.find(x => x.id === id);
  if (!b) return;
  const next = b.status === 'active' ? 'suspended' : 'active';
  const text = next === 'suspended'
    ? `¿Suspender "${b.name}"? Sus usuarios no podrán ingresar ni registrar sellos. Los datos se conservan.`
    : `¿Activar nuevamente "${b.name}"?`;
  if (!confirm(text)) return;
  const {error} = await sb.rpc('admin_set_business_status', {p_business_id: id, p_status: next});
  if (error) return message('bizMsg', error.message, true);
  message('bizMsg', `"${b.name}" ${next === 'active' ? 'activado' : 'suspendido'}.`);
  await refreshBusinessesEverywhere();
}
async function refreshBusinessesEverywhere() {
  await loadAllBusinesses();
  myBusinesses = allBusinesses.map(b => ({business: b, role: 'superadmin'}));
  renderBusinessPicker();
  if (currentBusiness) {
    const fresh = allBusinesses.find(b => b.id === currentBusiness.id);
    if (fresh) setBusiness(fresh, 'superadmin');
  } else if (allBusinesses.length) {
    await selectBusiness(allBusinesses[0].id);
  }
}

// ---------- superadmin: usuarios del negocio ----------
async function openUsers(id, scroll = true) {
  usersBusiness = allBusinesses.find(x => x.id === id);
  if (!usersBusiness) return;
  $('bizUsers').classList.remove('hidden');
  $('bizUsersName').textContent = usersBusiness.name;
  ['memberName', 'memberEmail', 'memberPassword'].forEach(x => $(x).value = '');
  message('memberMsg', '');
  await loadMembers();
  if (scroll) $('bizUsers').scrollIntoView({behavior: 'smooth'});
}
async function loadMembers() {
  if (!usersBusiness) return;
  $('memberRows').innerHTML = '<tr><td colspan="5">Cargando...</td></tr>';
  const {data, error} = await sb.rpc('list_business_members', {p_business_id: usersBusiness.id});
  if (error) {
    $('memberRows').innerHTML = `<tr><td colspan="5">Error: ${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  membersCache = data || [];
  $('memberRows').innerHTML = membersCache.map(m => `<tr>
    <td>${escapeHtml(m.full_name || '—')}</td>
    <td>${escapeHtml(m.email || '—')}</td>
    <td>${escapeHtml(ROLE_LABELS[m.role] || m.role)}</td>
    <td><span class="badge ${m.active ? 'ok' : 'off'}">${m.active ? 'Activo' : 'Inactivo'}</span></td>
    <td>
      <button class="small-action secondary" data-reset-pw="${escapeHtml(m.user_id)}">Restablecer contraseña</button>
      <button class="small-action ${m.active ? 'danger' : ''}" data-member-toggle="${escapeHtml(m.membership_id)}">${m.active ? 'Desactivar' : 'Activar'}</button>
    </td>
  </tr>`).join('') || '<tr><td colspan="5">Este negocio todavía no tiene usuarios.</td></tr>';
}
async function createMember() {
  if (!usersBusiness) return;
  const full_name = $('memberName').value.trim();
  const email = $('memberEmail').value.trim();
  const password = $('memberPassword').value;
  const role = $('memberRole').value;
  if (full_name.length < 2) return message('memberMsg', 'Escribe el nombre del usuario.', true);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return message('memberMsg', 'Escribe un correo válido.', true);
  if (password.length < 8) return message('memberMsg', 'La contraseña debe tener al menos 8 caracteres.', true);
  $('createMember').disabled = true;
  message('memberMsg', 'Creando usuario...');
  try {
    await callAdmin({action: 'create_user', business_id: usersBusiness.id, full_name, email, password, role});
    ['memberName', 'memberEmail', 'memberPassword'].forEach(x => $(x).value = '');
    await loadMembers();
    if (!membersCache.some(m => (m.email || '').toLowerCase() === email.toLowerCase())) {
      throw new Error('La función respondió, pero el usuario no aparece en el negocio. Revisa Supabase > Edge Functions > emisoft-admin > Logs.');
    }
    message('memberMsg', `Usuario creado. Entrega estos datos a ${full_name}: correo ${email} · contraseña ${password}`);
    if (currentBusiness?.id === usersBusiness.id) await loadStaffNames();
  } catch (e) {
    message('memberMsg', e.message, true);
  } finally {
    $('createMember').disabled = false;
  }
}
async function resetMemberPassword(userId) {
  const m = membersCache.find(x => x.user_id === userId);
  const who = m?.full_name || m?.email || 'este usuario';
  const pw = prompt(`Nueva contraseña para ${who} (mínimo 8 caracteres):`, randomPassword());
  if (pw === null) return;
  if (pw.length < 8) return message('memberMsg', 'La contraseña debe tener al menos 8 caracteres.', true);
  message('memberMsg', 'Restableciendo contraseña...');
  try {
    await callAdmin({action: 'reset_password', user_id: userId, new_password: pw});
    message('memberMsg', `Contraseña de ${who} restablecida. Nueva contraseña: ${pw}`);
  } catch (e) {
    message('memberMsg', e.message, true);
  }
}
async function toggleMember(membershipId) {
  const m = membersCache.find(x => x.membership_id === membershipId);
  if (!m) return;
  const who = m.full_name || m.email || 'este usuario';
  if (!confirm(m.active ? `¿Desactivar a ${who}? Ya no podrá ingresar a este negocio.` : `¿Activar a ${who}?`)) return;
  const {error} = await sb.rpc('admin_set_member_active', {p_membership_id: membershipId, p_active: !m.active});
  if (error) return message('memberMsg', error.message, true);
  message('memberMsg', `${who} ${m.active ? 'desactivado' : 'activado'}.`);
  await loadMembers();
}

// ---------- pestañas y eventos ----------
function showTab(tabName) {
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tabName));
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.toggle('hidden', p.id !== tabName));
  if (tabName !== 'scanner') stopScanner(false);
  if (tabName === 'history') loadHistory();
  if (tabName === 'settings') loadPrograms();
  if (tabName === 'audit') loadAudit();
  if (tabName === 'businesses') loadAllBusinesses();
}

$('loginBtn').addEventListener('click', login);
$('password').addEventListener('keydown', e => { if (e.key === 'Enter') login(); });
$('logout').addEventListener('click', logout);
$('businessPicker').addEventListener('change', e => selectBusiness(e.target.value));
$('createCustomer').addEventListener('click', createCustomer);
$('filter').addEventListener('input', renderCustomers);
$('downloadQr').addEventListener('click', downloadQr);
$('closeQr').addEventListener('click', () => $('newCard').classList.add('hidden'));
$('startScan').addEventListener('click', startScanner);
$('stopScan').addEventListener('click', () => stopScanner());
$('saveProgram').addEventListener('click', saveProgram);
$('addMilestone').addEventListener('click', () => $('milestoneRows').appendChild(milestoneRow()));
$('milestoneRows').addEventListener('click', e => { if (e.target.closest('.ms-remove')) e.target.closest('.milestone-row').remove(); });
$('templateButtons').addEventListener('click', e => {
  const b = e.target.closest('[data-template]');
  if (!b) return;
  fillProgramForm(TEMPLATES[b.dataset.template]);
  message('settingsMsg', `Ejemplo "${b.dataset.template}" cargado. Ajusta los textos y premios a tu negocio y pulsa "Guardar nueva política".`);
});
document.querySelectorAll('.qty-btn').forEach(b => b.addEventListener('click', () => {
  $('scanQty').value = Math.min(100, Math.max(1, (Number($('scanQty').value) || 1) + Number(b.dataset.qty)));
}));
$('refreshHistory').addEventListener('click', loadHistory);
$('refreshAudit').addEventListener('click', loadAudit);
$('saveBusiness').addEventListener('click', saveBusiness);
$('cancelBusinessEdit').addEventListener('click', () => { resetBusinessForm(); message('bizMsg', ''); });
$('bizLogo').addEventListener('change', previewLogo);
$('bizCategory').innerHTML = '<option value="">— Selecciona el rubro —</option>' + CATEGORIES.map(c => `<option>${escapeHtml(c)}</option>`).join('');
$('genPassword').addEventListener('click', () => $('memberPassword').value = randomPassword());
$('createMember').addEventListener('click', createMember);

$('customerRows').addEventListener('click', e => {
  const redeem = e.target.closest('[data-redeem-card]');
  if (redeem) return redeemCard(redeem.dataset.redeemCard);
  const plus = e.target.closest('[data-add-stamp]');
  if (plus) return addStampManual(plus.dataset.addStamp);
  const ms = e.target.closest('[data-redeem-ms]');
  if (ms) return redeemMilestone(ms.dataset.card, ms.dataset.redeemMs);
  const qr = e.target.closest('[data-show-qr]');
  if (qr) {
    const c = customersCache.find(x => x.id === qr.dataset.showQr);
    if (c?.qr_token) showQr('Tarjeta del cliente', c.full_name, c.phone, c.qr_token);
  }
});
$('businessRows').addEventListener('click', async e => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.dataset.bizEdit) editBusiness(b.dataset.bizEdit);
  if (b.dataset.bizPolicy) { await selectBusiness(b.dataset.bizPolicy); showTab('settings'); window.scrollTo({top: 0, behavior: 'smooth'}); }
  if (b.dataset.bizUsers) { await selectBusiness(b.dataset.bizUsers); $('bizUsers').scrollIntoView({behavior: 'smooth'}); }
  if (b.dataset.bizStatus) toggleBusinessStatus(b.dataset.bizStatus);
  if (b.dataset.bizOpen) { await selectBusiness(b.dataset.bizOpen); showTab('customers'); window.scrollTo({top: 0, behavior: 'smooth'}); }
});
$('memberRows').addEventListener('click', e => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.dataset.resetPw) resetMemberPassword(b.dataset.resetPw);
  if (b.dataset.memberToggle) toggleMember(b.dataset.memberToggle);
});
document.querySelectorAll('.tab').forEach(btn => btn.addEventListener('click', () => showTab(btn.dataset.tab)));

init();
