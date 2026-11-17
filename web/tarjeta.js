// EMISOFT Fidelización Digital · Tarjeta del cliente · v1.3.2
(async () => {
  const $ = id => document.getElementById(id);
  const show = (id, on = true) => $(id).classList.toggle('hidden', !on);
  const fmt = d => new Date(d).toLocaleString('es', {day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit'});

  function fail(text) {
    show('loading', false);
    show('error');
    $('errorText').textContent = text;
  }

  const token = (new URLSearchParams(location.search).get('t') || '').trim().toLowerCase();
  if (!/^[0-9a-f]{32,128}$/.test(token)) return fail('El enlace de la tarjeta no es válido. Pide al negocio que te comparta tu código nuevamente.');
  if (!window.supabase?.createClient) return fail('No se pudo cargar la página. Revisa tu conexión a internet.');

  const sb = window.supabase.createClient(window.EMISOFT_SUPABASE_URL, window.EMISOFT_SUPABASE_ANON_KEY,
    {auth: {persistSession: false, autoRefreshToken: false}});
  const {data: c, error} = await sb.rpc('get_public_card', {p_token: token});
  if (error) return fail(error.message || 'No se pudo cargar la tarjeta.');

  document.title = 'Mi tarjeta · ' + c.business_name;
  $('bizName').textContent = c.business_name;
  if (typeof c.business_logo === 'string' && /^https:\/\//i.test(c.business_logo)) {
    $('bizLogo').src = c.business_logo;
    $('bizLogo').alt = 'Logo de ' + c.business_name;
    show('bizLogo');
  }
  $('customerName').textContent = c.customer_name || 'cliente';

  const required = Number(c.stamps_required || 0);
  const count = Math.min(Number(c.stamps_count || 0), required || Infinity);
  $('count').textContent = count;
  $('required').textContent = required || '—';
  $('reward').textContent = c.reward || 'Consulta en el negocio';
  show('completeBanner', !!c.completed);
  $('remaining').textContent = c.completed ? '¡Listo para canjear!'
    : required ? `Te ${required - count === 1 ? 'falta 1 sello' : 'faltan ' + (required - count) + ' sellos'}` : '';

  // Los sellos obtenidos muestran el logo del negocio (o ✓ si no tiene logo).
  const logo = typeof c.business_logo === 'string' && /^https:\/\//i.test(c.business_logo) ? c.business_logo : '';
  if (required > 0 && required <= 30) {
    $('stamps').innerHTML = Array.from({length: required}, (_, i) => `<span class="stamp"></span>`).join('');
    const iconAt = {};
    (c.milestones || []).forEach(m => iconAt[m.stamps_at] = m.icon || '🎁');
    iconAt[required] = iconAt[required] || '🏆';
    [...$('stamps').children].forEach((el, i) => {
      const icon = iconAt[i + 1];
      if (icon) el.classList.add('gift');
      if (i >= count) { el.textContent = icon || i + 1; return; }
      if (icon) el.dataset.icon = icon;
      el.classList.add('on');
      if (logo) {
        el.classList.add('logo-stamp');
        const img = document.createElement('img');
        img.src = logo; img.alt = '';
        img.onerror = () => { el.classList.remove('logo-stamp'); el.textContent = '✓'; };
        el.appendChild(img);
      } else {
        el.textContent = '✓';
      }
    });
  } else if (required > 0) {
    show('bar');
    $('barFill').style.width = Math.round(count / required * 100) + '%';
  }

  // Próximo premio: motiva a volver (no revela el contenido de una sorpresa).
  if (!c.completed && required > 0) {
    const next = (c.milestones || []).filter(m => !m.reached).sort((a, b) => a.stamps_at - b.stamps_at)[0];
    const at = next ? next.stamps_at : required;
    const left = at - count;
    const what = !next ? `tu premio final: ${c.reward}` : next.surprise ? 'tu sorpresa' : next.reward;
    $('nextIcon').textContent = next ? (next.icon || '🎁') : '🏆';
    $('nextText').textContent = left === 1 ? `¡Solo te falta 1 visita para ${what}!` : `Te faltan ${left} visitas para ${what}`;
    $('nextGoal').classList.toggle('urgent', left === 1);
    show('nextGoal');
  }
  const ready = (c.milestones || []).filter(m => m.reached && !m.redeemed);
  if (ready.length && !c.completed) {
    $('completeBanner').textContent = `🎉 ¡Ganaste ${ready.map(m => m.reward).join(' y ')}! Pídelo en caja mostrando este código.`;
    show('completeBanner');
  }

  if (c.stamp_rule) { $('rule').textContent = 'Cómo ganar sellos: ' + c.stamp_rule; show('rule'); }
  const ms = c.milestones || [];
  if (ms.length) {
    $('milestones').innerHTML = '<span class="label">Premios en el camino</span>' + ms.map(m => {
      const state = m.redeemed ? ['done', 'Canjeado'] : m.reached ? ['ready', '¡Disponible! Pídelo en caja'] : ['', `En el sello ${m.stamps_at}`];
      return `<div class="ms ${state[0]} ${m.surprise && !m.reached ? 'surprise' : ''}"><span class="ms-at"></span><span class="ms-text"></span><span class="ms-state">${state[1]}</span></div>`;
    }).join('');
    [...$('milestones').querySelectorAll('.ms')].forEach((el, i) => {
      const m = ms[i];
      el.querySelector('.ms-at').textContent = m.icon || '🎁';
      el.querySelector('.ms-text').textContent = m.reward ?? '¡Sorpresa! Se revela al llegar a este sello';
    });
    show('milestones');
  }

  // El QR de esta página es el mismo que escanea el cajero.
  if (window.QRCode) {
    new QRCode($('qr'), {text: location.href.split('#')[0], width: 220, height: 220, correctLevel: QRCode.CorrectLevel.M});
  }

  const stamps = c.recent_stamps || [];
  $('stampList').innerHTML = stamps.length
    ? stamps.map((d, i) => `<li><span>Sello ${stamps.length - i}</span><span class="muted">${fmt(d)}</span></li>`).join('')
    : '<li class="muted">Todavía no tienes sellos en este ciclo.</li>';
  const reds = c.redemptions || [];
  $('redemptionList').innerHTML = reds.length
    ? reds.map(r => `<li><span>${String(r.reward).replace(/[&<>"']/g, '')}</span><span class="muted">${fmt(r.date)}</span></li>`).join('')
    : '<li class="muted">Aún no has canjeado premios.</li>';
  $('memberSince').textContent = 'Cliente desde ' + new Date(c.member_since).toLocaleDateString('es', {day: 'numeric', month: 'long', year: 'numeric'});

  show('loading', false);
  show('card');
  show('historyBox');
})();
