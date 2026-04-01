(function () {
  const isFileProtocol = window.location.protocol === 'file:';
  const nav = document.querySelector('.main-nav');
  const toggle = document.querySelector('[data-menu-toggle]');

  if (toggle && nav) {
    toggle.addEventListener('click', function () {
      nav.classList.toggle('open');
      const expanded = nav.classList.contains('open');
      toggle.setAttribute('aria-expanded', String(expanded));
    });

    nav.querySelectorAll('a').forEach(function (link) {
      link.addEventListener('click', function () {
        nav.classList.remove('open');
        toggle.setAttribute('aria-expanded', 'false');
      });
    });
  }

  const page = document.body.getAttribute('data-page');
  if (page && nav) {
    const active = nav.querySelector('[data-nav="' + page + '"]');
    if (active) active.classList.add('active');
  }

  const observer = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('show');
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.15 }
  );

  document.querySelectorAll('.reveal').forEach(function (el) {
    observer.observe(el);
  });

  function setStatus(el, text, color) {
    if (!el) return;
    el.textContent = text;
    el.style.color = color;
  }

  async function postJson(url, data) {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });

    let payload = {};
    try {
      payload = await response.json();
    } catch (error) {
      payload = {};
    }

    if (!response.ok) {
      const message = payload.message || '请求失败';
      throw new Error(message);
    }

    return payload;
  }

  const form = document.querySelector('#contact-form');
  if (form) {
    const status = document.querySelector('.form-status');

    if (isFileProtocol) {
      setStatus(status, '当前是本地文件模式，预约提交不可用。请先启动 http://localhost:8080 服务。', '#dc2626');
    }

    form.addEventListener('submit', async function (event) {
      event.preventDefault();

      if (isFileProtocol) {
        setStatus(status, '请通过 http://localhost:8080 访问后再提交。', '#dc2626');
        return;
      }

      const formData = new FormData(form);
      const payload = {
        name: String(formData.get('name') || '').trim(),
        phone: String(formData.get('phone') || '').trim(),
        studentAge: String(formData.get('studentAge') || '').trim(),
        message: String(formData.get('message') || '').trim()
      };

      if (!payload.name || !payload.phone) {
        setStatus(status, '请先填写姓名和手机号。', '#dc2626');
        return;
      }

      try {
        setStatus(status, '正在提交，请稍候...', '#0f766e');
        await postJson('/api/appointments', payload);
        setStatus(status, '提交成功，我们会在 1 个工作日内与您联系。', '#0f766e');
        form.reset();
      } catch (error) {
        setStatus(status, error.message || '提交失败，请稍后重试。', '#dc2626');
      }
    });
  }

  const adminApp = document.querySelector('[data-admin-app]');
  if (!adminApp) {
    return;
  }

  const loginCard = adminApp.querySelector('[data-admin-login]');
  const panelCard = adminApp.querySelector('[data-admin-panel]');
  const loginForm = adminApp.querySelector('#admin-login-form');
  const loginStatus = adminApp.querySelector('.admin-login-status');
  const tableBody = adminApp.querySelector('#appointment-table-body');
  const panelStatus = adminApp.querySelector('.admin-panel-status');
  const refreshButton = adminApp.querySelector('[data-refresh]');
  const logoutButton = adminApp.querySelector('[data-logout]');

  function escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function renderRows(items) {
    if (!tableBody) return;

    if (!items.length) {
      tableBody.innerHTML = '<tr><td colspan="5">暂无预约信息</td></tr>';
      return;
    }

    tableBody.innerHTML = items
      .map(function (item) {
        return (
          '<tr>' +
          '<td>' + escapeHtml(item.createdAt) + '</td>' +
          '<td>' + escapeHtml(item.name) + '</td>' +
          '<td>' + escapeHtml(item.phone) + '</td>' +
          '<td>' + escapeHtml(item.studentAge || '-') + '</td>' +
          '<td>' + escapeHtml(item.message || '-') + '</td>' +
          '</tr>'
        );
      })
      .join('');
  }

  function showPanel(show) {
    if (loginCard) loginCard.style.display = show ? 'none' : 'block';
    if (panelCard) panelCard.style.display = show ? 'block' : 'none';
  }

  async function fetchAppointments() {
    const response = await fetch('/api/appointments', { method: 'GET' });
    let payload = {};

    try {
      payload = await response.json();
    } catch (error) {
      payload = {};
    }

    if (!response.ok) {
      const message = payload.message || '获取数据失败';
      const err = new Error(message);
      err.status = response.status;
      throw err;
    }

    return payload.items || [];
  }

  async function loadAppointments() {
    if (isFileProtocol) {
      showPanel(false);
      setStatus(loginStatus, '当前是 file:// 打开，后台接口不可用。请先启动服务并访问 http://localhost:8080/admin.html', '#dc2626');
      return;
    }

    try {
      setStatus(panelStatus, '正在加载预约信息...', '#0f766e');
      const items = await fetchAppointments();
      renderRows(items);
      setStatus(panelStatus, '已加载 ' + items.length + ' 条预约记录。', '#0f766e');
      showPanel(true);
    } catch (error) {
      if (error.status === 401) {
        showPanel(false);
        setStatus(loginStatus, '请先登录后台。', '#64748b');
        return;
      }

      setStatus(panelStatus, error.message || '加载失败', '#dc2626');
    }
  }

  if (loginForm) {
    loginForm.addEventListener('submit', async function (event) {
      event.preventDefault();

      if (isFileProtocol) {
        setStatus(loginStatus, '请通过 http://localhost:8080/admin.html 登录后台。', '#dc2626');
        return;
      }

      const formData = new FormData(loginForm);
      const username = String(formData.get('username') || '').trim();
      const password = String(formData.get('password') || '').trim();

      if (!username || !password) {
        setStatus(loginStatus, '请输入账号和密码。', '#dc2626');
        return;
      }

      try {
        setStatus(loginStatus, '正在登录...', '#0f766e');
        await postJson('/api/login', { username: username, password: password });
        setStatus(loginStatus, '登录成功。', '#0f766e');
        loginForm.reset();
        await loadAppointments();
      } catch (error) {
        setStatus(loginStatus, error.message || '登录失败。', '#dc2626');
      }
    });
  }

  if (refreshButton) {
    refreshButton.addEventListener('click', function () {
      loadAppointments();
    });
  }

  if (logoutButton) {
    logoutButton.addEventListener('click', async function () {
      if (!isFileProtocol) {
        try {
          await postJson('/api/logout', {});
        } catch (error) {
        }
      }

      showPanel(false);
      setStatus(loginStatus, '已退出登录。', '#64748b');
      setStatus(panelStatus, '', '#64748b');
      if (tableBody) tableBody.innerHTML = '';
    });
  }

  loadAppointments();
})();
