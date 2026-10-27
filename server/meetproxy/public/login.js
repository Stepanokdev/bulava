document.getElementById('f').addEventListener('submit', async (e) => {
  e.preventDefault();
  const err = document.getElementById('err');
  const btn = e.target.querySelector('button');
  err.textContent = ''; btn.disabled = true;
  try {
    const r = await fetch('/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ login: e.target.login.value, password: e.target.password.value }) });
    if (r.ok) { location.href = '/'; return; }
    err.textContent = (await r.json().catch(() => ({}))).error || 'Не вдалося увійти.';
  } catch { err.textContent = 'Немає зв’язку з сервером.'; }
  btn.disabled = false;
});
