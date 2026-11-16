/* MailRotator Mini App - client.
   Polls the Node service for a snapshot and renders the dashboard. The page
   holds no domain data of its own: every value comes from the service. */

(function () {
  'use strict';

  var POLL_ACTIVE_MS = 2000;
  var POLL_IDLE_MS = 6000;

  var el = {
    headline: document.getElementById('headline'),
    runStatus: document.getElementById('runStatus'),
    openRunDialog: document.getElementById('openRunDialog'),
    alertBox: document.getElementById('alertBox'),
    projectCard: document.getElementById('projectCard'),
    projectForm: document.getElementById('projectForm'),
    projectPath: document.getElementById('projectPath'),
    projectHint: document.getElementById('projectHint'),
    kpiSent: document.getElementById('kpiSent'),
    kpiFailed: document.getElementById('kpiFailed'),
    kpiSkipped: document.getElementById('kpiSkipped'),
    kpiRotations: document.getElementById('kpiRotations'),
    kpiSentNote: document.getElementById('kpiSentNote'),
    kpiFailedNote: document.getElementById('kpiFailedNote'),
    kpiSkippedNote: document.getElementById('kpiSkippedNote'),
    kpiRotationsNote: document.getElementById('kpiRotationsNote'),
    liveMeta: document.getElementById('liveMeta'),
    progressTrack: document.getElementById('progressTrack'),
    progressFill: document.getElementById('progressFill'),
    factMode: document.getElementById('factMode'),
    factIp: document.getElementById('factIp'),
    factVariant: document.getElementById('factVariant'),
    factBatches: document.getElementById('factBatches'),
    console: document.getElementById('console'),
    clearConsole: document.getElementById('clearConsole'),
    variantTable: document.getElementById('variantTable').querySelector('tbody'),
    variantEmpty: document.getElementById('variantEmpty'),
    variantMeta: document.getElementById('variantMeta'),
    rotationTable: document.getElementById('rotationTable').querySelector('tbody'),
    rotationEmpty: document.getElementById('rotationEmpty'),
    rotationMeta: document.getElementById('rotationMeta'),
    ipTable: document.getElementById('ipTable').querySelector('tbody'),
    ipEmpty: document.getElementById('ipEmpty'),
    runsList: document.getElementById('runsList'),
    runsEmpty: document.getElementById('runsEmpty'),
    runsMeta: document.getElementById('runsMeta'),
    suppressedCount: document.getElementById('suppressedCount'),
    cfgHost: document.getElementById('cfgHost'),
    cfgUser: document.getElementById('cfgUser'),
    cfgBatch: document.getElementById('cfgBatch'),
    cfgCreative: document.getElementById('cfgCreative'),
    cfgProxy: document.getElementById('cfgProxy'),
    cfgConsent: document.getElementById('cfgConsent'),
    cfgDomains: document.getElementById('cfgDomains'),
    runDialog: document.getElementById('runDialog'),
    closeRunDialog: document.getElementById('closeRunDialog'),
    cancelRun: document.getElementById('cancelRun'),
    runForm: document.getElementById('runForm'),
    runMax: document.getElementById('runMax'),
    runBatch: document.getElementById('runBatch'),
    runConfig: document.getElementById('runConfig'),
    runRecipients: document.getElementById('runRecipients'),
    runPassword: document.getElementById('runPassword'),
    runProxyPassword: document.getElementById('runProxyPassword'),
    passwordField: document.getElementById('passwordField'),
    proxyPasswordField: document.getElementById('proxyPasswordField'),
    startRun: document.getElementById('startRun'),
  };

  var state = {
    snapshot: null,
    lastOutput: [],
    consoleHidden: false,
    lastStartedAt: '',
    timer: null,
    busy: false,
  };

  function text(node, value) {
    node.textContent = value === null || value === undefined || value === '' ? '—' : String(value);
  }

  function showAlert(message) {
    el.alertBox.textContent = message;
    el.alertBox.hidden = false;
  }

  function clearAlert() {
    el.alertBox.textContent = '';
    el.alertBox.hidden = true;
  }

  function getJson(url) {
    return fetch(url, { headers: { accept: 'application/json' } }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  function postJson(url, body) {
    return fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body || {}),
    }).then(function (r) {
      return r.json().then(function (data) {
        if (!r.ok) throw new Error(data && data.message ? data.message : 'HTTP ' + r.status);
        return data;
      });
    });
  }

  function formatTime(iso) {
    if (!iso) return '—';
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '—';
    return d.toLocaleString('ar', { hour12: false });
  }

  // ------------------------------------------------------------- rendering --

  function renderProject(snapshot) {
    var project = snapshot.project || {};
    var configured = !!project.configured;
    el.projectCard.hidden = configured && !project.reason;
    el.projectPath.value = project.projectPath || el.projectPath.value || '';
    if (project.reason) {
      el.projectHint.textContent = project.reason;
    } else if (configured) {
      el.projectHint.textContent = 'المشروع جاهز: ' + project.projectPath;
    }
    el.headline.textContent = configured
      ? 'مراقبة التشغيل الحي وإدارة campaigns الإرسال.'
      : 'حدّد مجلد المشروع للبدء.';
    el.openRunDialog.disabled = !configured;
  }

  function renderConfig(snapshot) {
    var config = snapshot.config;
    if (!config) {
      text(el.cfgHost, '');
      text(el.cfgUser, '');
      text(el.cfgBatch, '');
      text(el.cfgCreative, '');
      text(el.cfgProxy, '');
      text(el.cfgConsent, '');
      el.cfgDomains.textContent = '—';
      return;
    }
    text(el.cfgHost, config.smtpHost);
    text(el.cfgUser, config.smtpUser);
    text(el.cfgBatch, config.batchSize + ' رسالة');
    text(el.cfgCreative, config.creativeRotateEvery + ' رسالة');
    text(el.cfgProxy, config.proxyMode);
    text(el.cfgConsent, config.consentBasis);
    el.cfgDomains.textContent = 'النطاقات المسموحة: ' + (config.allowedDomains || []).join('، ');
  }

  function renderKpis(snapshot) {
    var live = snapshot.live;
    var report = snapshot.latestReport;
    var job = snapshot.job || {};
    var running = !!job.running;

    var sent = 0;
    var failed = 0;
    var skipped = 0;
    var rotations = 0;
    var source = '';

    if (running && live && live.totals) {
      sent = live.totals.sent;
      failed = live.totals.failed;
      skipped = live.totals.skipped;
      rotations = live.totals.rotations;
      source = 'من التشغيل الحي';
    } else if (report) {
      sent = report.totals.sent;
      failed = report.totals.failed;
      skipped = report.totals.skipped;
      rotations = report.totals.rotations;
      source = 'آخر تشغيل مكتمل';
    }

    el.kpiSent.textContent = sent;
    el.kpiFailed.textContent = failed;
    el.kpiSkipped.textContent = skipped;
    el.kpiRotations.textContent = rotations;
    el.kpiSentNote.textContent = source || 'لا يوجد تشغيل بعد';
    el.kpiFailedNote.textContent = source ? source : 'لا يوجد تشغيل بعد';
    el.kpiSkippedNote.textContent = source ? source : 'خارج النطاق أو مسبق المعالجة';
    el.kpiRotationsNote.textContent = source ? source : 'تبديل عنوان الخروج';

    var checkpoint = snapshot.checkpoint;
    if (checkpoint && !running) {
      el.kpiSentNote.textContent =
        'نقطة الاستئناف: ' + checkpoint.sentCount + ' مُرسَل، ' + checkpoint.processed + ' تمت معالجته';
    }
  }

  function renderLive(snapshot) {
    var job = snapshot.job || {};
    var live = snapshot.live;
    var running = !!job.running;

    if (running) {
      el.runStatus.textContent = 'يعمل الآن';
      el.runStatus.dataset.state = 'running';
    } else if (job.stopped) {
      el.runStatus.textContent = 'أُوقف';
      el.runStatus.dataset.state = 'stopped';
    } else if (job.exitCode !== null && job.exitCode !== undefined) {
      el.runStatus.textContent = job.exitCode === 0 ? 'اكتمل' : 'فشل';
      el.runStatus.dataset.state = job.exitCode === 0 ? 'done' : 'stopped';
    } else {
      el.runStatus.textContent = 'جاهز';
      el.runStatus.dataset.state = 'idle';
    }

    var mode = job.mode === 'send' ? 'إرسال فعلي' : 'تجربة';
    if (!running && !job.startedAt) mode = '—';
    text(el.factMode, mode);
    text(el.factIp, live && live.currentIp ? live.currentIp : '—');
    text(el.factVariant, live && live.currentVariant ? live.currentVariant : '—');
    text(el.factBatches, live && live.totals ? live.totals.batches : '—');
    el.liveMeta.textContent = live && live.runFile ? live.runFile : '—';

    var max = job.maxMessages || 0;
    var done = live && live.totals ? live.totals.sent + live.totals.failed : 0;
    var percent = max > 0 ? Math.min(100, Math.round((done / max) * 100)) : 0;
    el.progressFill.style.width = percent + '%';
    el.progressTrack.setAttribute('aria-valuenow', String(percent));

    if (job.startedAt && job.startedAt !== state.lastStartedAt) {
      state.lastStartedAt = job.startedAt;
      state.lastOutput = [];
      state.consoleHidden = false;
      el.console.textContent = '';
    }

    var output = job.output || [];
    if (!state.consoleHidden && output.length > 0) {
      var changed = output.length !== state.lastOutput.length;
      if (!changed) {
        for (var i = 0; i < output.length; i += 1) {
          if (output[i] !== state.lastOutput[i]) {
            changed = true;
            break;
          }
        }
      }
      if (changed) {
        var atBottom =
          el.console.scrollHeight - el.console.scrollTop - el.console.clientHeight < 40;
        state.lastOutput = output.slice();
        el.console.textContent = output.join('\n');
        if (atBottom) el.console.scrollTop = el.console.scrollHeight;
      }
    }
  }

  function renderVariants(snapshot) {
    var report = snapshot.latestReport;
    var rows = report && report.perVariant ? report.perVariant : [];
    el.variantTable.innerHTML = '';
    el.variantEmpty.hidden = rows.length > 0;
    el.variantMeta.textContent = rows.length ? rows.length + ' نسخة' : '—';
    rows.forEach(function (v) {
      var tr = document.createElement('tr');
      [v.Variant, v.Sent, v.Failed, v.Skipped, v.Total].forEach(function (value) {
        var td = document.createElement('td');
        td.textContent = String(value);
        tr.appendChild(td);
      });
      el.variantTable.appendChild(tr);
    });
  }

  function renderRotations(snapshot) {
    var report = snapshot.latestReport;
    var rows = report && report.rotations ? report.rotations : [];
    el.rotationTable.innerHTML = '';
    el.rotationEmpty.hidden = rows.length > 0;
    el.rotationMeta.textContent = rows.length ? rows.length + ' تدوير' : '—';
    rows.forEach(function (r) {
      var tr = document.createElement('tr');
      [r.rotationIndex, r.egressIp, r.sessionId, r.previousIp || '—'].forEach(function (value) {
        var td = document.createElement('td');
        td.textContent = String(value);
        tr.appendChild(td);
      });
      el.rotationTable.appendChild(tr);
    });
  }

  function renderIps(snapshot) {
    var report = snapshot.latestReport;
    var rows = report && report.perIp ? report.perIp : [];
    el.ipTable.innerHTML = '';
    el.ipEmpty.hidden = rows.length > 0;
    rows.forEach(function (r) {
      var tr = document.createElement('tr');
      [r.EgressIp, r.Sent, r.Failed].forEach(function (value) {
        var td = document.createElement('td');
        td.textContent = String(value);
        tr.appendChild(td);
      });
      el.ipTable.appendChild(tr);
    });
  }

  function renderRuns(snapshot) {
    var runs = snapshot.recentRuns || [];
    el.runsList.innerHTML = '';
    el.runsEmpty.hidden = runs.length > 0;
    el.runsMeta.textContent = runs.length ? runs.length + ' تشغيل' : '—';
    runs.forEach(function (run) {
      var li = document.createElement('li');
      var name = document.createElement('span');
      name.className = 'run-name';
      name.textContent = run.file;
      var time = document.createElement('span');
      time.className = 'run-time';
      time.textContent = formatTime(run.modifiedAt);
      li.appendChild(name);
      li.appendChild(time);
      el.runsList.appendChild(li);
    });
  }

  function render(snapshot) {
    state.snapshot = snapshot;
    renderProject(snapshot);
    renderConfig(snapshot);
    renderKpis(snapshot);
    renderLive(snapshot);
    renderVariants(snapshot);
    renderRotations(snapshot);
    renderIps(snapshot);
    renderRuns(snapshot);
    el.suppressedCount.textContent = String(snapshot.suppressedCount || 0);
  }

  // -------------------------------------------------------------- polling --

  function schedule(delay) {
    if (state.timer) clearTimeout(state.timer);
    state.timer = setTimeout(poll, delay);
  }

  function poll() {
    getJson('/api/state')
      .then(function (snapshot) {
        render(snapshot);
        clearAlert();
        var running = snapshot.job && snapshot.job.running;
        schedule(running ? POLL_ACTIVE_MS : POLL_IDLE_MS);
      })
      .catch(function (error) {
        showAlert('تعذّر قراءة الحالة: ' + error.message);
        schedule(POLL_IDLE_MS * 2);
      });
  }

  // --------------------------------------------------------------- dialog --

  function openDialog() {
    clearAlert();
    var snapshot = state.snapshot;
    var config = snapshot && snapshot.config;
    el.runMax.value = '';
    el.runBatch.value = config && config.batchSize ? String(config.batchSize) : '';
    el.runConfig.value = 'config/config.json';
    el.runRecipients.value = 'data/recipients.csv';
    el.runPassword.value = '';
    el.runProxyPassword.value = '';
    syncModeFields(config);
    el.runDialog.hidden = false;
    var first = el.runForm.querySelector('input');
    if (first) first.focus();
  }

  function closeDialog() {
    el.runDialog.hidden = true;
    el.runPassword.value = '';
    el.runProxyPassword.value = '';
    el.openRunDialog.focus();
  }

  function currentMode() {
    var checked = el.runForm.querySelector('input[name="mode"]:checked');
    return checked ? checked.value : 'dry';
  }

  function syncModeFields(config) {
    var sending = currentMode() === 'send';
    el.passwordField.hidden = !sending;
    var proxyNeeded = sending && config && config.proxyMode && config.proxyMode !== 'none';
    el.proxyPasswordField.hidden = !proxyNeeded;
  }

  el.runForm.addEventListener('change', function (event) {
    if (event.target && event.target.name === 'mode') {
      syncModeFields(state.snapshot && state.snapshot.config);
    }
  });

  el.openRunDialog.addEventListener('click', openDialog);
  el.closeRunDialog.addEventListener('click', closeDialog);
  el.cancelRun.addEventListener('click', closeDialog);
  el.runDialog.addEventListener('click', function (event) {
    if (event.target === el.runDialog) closeDialog();
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && !el.runDialog.hidden) closeDialog();
  });

  el.clearConsole.addEventListener('click', function () {
    state.consoleHidden = true;
    state.lastOutput = [];
    el.console.textContent = '';
  });

  el.projectForm.addEventListener('submit', function (event) {
    event.preventDefault();
    postJson('/api/settings', { projectPath: el.projectPath.value })
      .then(function () {
        clearAlert();
        poll();
      })
      .catch(function (error) {
        showAlert(error.message);
      });
  });

  el.runForm.addEventListener('submit', function (event) {
    event.preventDefault();
    if (state.busy) return;
    var payload = {
      mode: currentMode(),
      maxMessages: Number(el.runMax.value || 0),
      batchSize: Number(el.runBatch.value || 0),
      configPath: el.runConfig.value.trim(),
      recipientsPath: el.runRecipients.value.trim(),
      skipUrlChecks: el.runForm.querySelector('input[name="skipUrlChecks"]').checked,
      smtpPassword: el.runPassword.value,
      proxyPassword: el.runProxyPassword.value,
    };
    state.busy = true;
    el.startRun.disabled = true;
    postJson('/api/run', payload)
      .then(function () {
        state.consoleHidden = false;
        state.lastOutput = [];
        state.lastStartedAt = '';
        el.console.textContent = '';
        closeDialog();
        poll();
      })
      .catch(function (error) {
        showAlert(error.message);
      })
      .then(function () {
        state.busy = false;
        el.startRun.disabled = false;
        // The password never stays in the form after a run is requested.
        el.runPassword.value = '';
        el.runProxyPassword.value = '';
      });
  });

  // ------------------------------------------------------------ view state --

  var VIEW_KEY = 'mowafak-mailrotator.view';

  function saveView() {
    try {
      sessionStorage.setItem(
        VIEW_KEY,
        JSON.stringify({
          scroll: window.scrollY,
          consoleScroll: el.console.scrollTop,
          at: new Date().toISOString(),
        }),
      );
    } catch (error) {
      /* storage is optional */
    }
  }

  function restoreView() {
    try {
      var raw = sessionStorage.getItem(VIEW_KEY);
      if (!raw) return;
      var view = JSON.parse(raw);
      if (view.consoleScroll) el.console.scrollTop = view.consoleScroll;
      if (view.scroll) window.scrollTo(0, view.scroll);
    } catch (error) {
      /* storage is optional */
    }
  }

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') saveView();
  });

  restoreView();
  poll();
})();
