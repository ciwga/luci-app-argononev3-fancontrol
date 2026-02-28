'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require rpc';

var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: [ 'name' ],
    expect: { '': {} }
});

// ==============================================================================
// Helpers (zero-allocation where possible)
// ==============================================================================
function formatUptime(s) {
    if (!s || s < 0) return 'N/A';
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600),
        m = Math.floor((s % 3600) / 60), sec = s % 60;
    if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
    if (h > 0) return h + 'h ' + m + 'm ' + sec + 's';
    if (m > 0) return m + 'm ' + sec + 's';
    return sec + 's';
}

// Fixed-size ring buffer for sparkline (20 samples, ~60s at 3s poll)
var _tHist = [], _tMax = 20;
function pushTemp(t) { _tHist.push(t); if (_tHist.length > _tMax) _tHist.shift(); }

function sparkSvg(data) {
    if (!data || data.length < 2) return '';
    var w = 120, h = 22, p = 2, mn = data[0], mx = data[0];
    for (var i = 1; i < data.length; i++) { if (data[i] < mn) mn = data[i]; if (data[i] > mx) mx = data[i]; }
    if (mx - mn < 5) mn = mx - 5;
    var pts = '';
    for (var j = 0; j < data.length; j++) {
        var x = p + (j / (data.length - 1)) * (w - 2 * p);
        var y = p + (1 - (data[j] - mn) / (mx - mn)) * (h - 2 * p);
        pts += x.toFixed(1) + ',' + y.toFixed(1) + ' ';
    }
    var c = data[data.length - 1] >= 80 ? '#ef4444' : (data[data.length - 1] >= 60 ? '#f59e0b' : '#22c55e');
    return '<svg width="' + w + '" height="' + h + '" style="vertical-align:middle;margin-left:8px;">' +
           '<polyline points="' + pts.trim() + '" fill="none" stroke="' + c + '" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
}

// ==============================================================================
// Cooling Presets (zero runtime cost - just UCI values applied on click)
// Optimized for RPi 5 in Argon ONE V3 case thermal characteristics.
// ==============================================================================
var PRESETS = {
    silent:      { temp_quiet: '55', speed_quiet: '15', temp_low: '62', speed_low: '30', temp_med: '70', speed_med: '50', temp_high: '78', speed_high: '75', hysteresis: '5' },
    balanced:    { temp_quiet: '50', speed_quiet: '25', temp_low: '58', speed_low: '50', temp_med: '65', speed_med: '75', temp_high: '72', speed_high: '100', hysteresis: '3' },
    performance: { temp_quiet: '42', speed_quiet: '30', temp_low: '50', speed_low: '55', temp_med: '58', speed_med: '80', temp_high: '65', speed_high: '100', hysteresis: '2' }
};

return view.extend({
    load: function() {
        var getFallbackTemp = function() {
            return fs.trimmed('/sys/class/thermal/thermal_zone0/temp').catch(function() {
                return fs.trimmed('/sys/class/thermal/thermal_zone1/temp').catch(function() { return '0'; });
            });
        };

        return Promise.all([
            callServiceList('argon_daemon').catch(function() { return {}; }),
            fs.read_direct('/var/run/argon_fan.status').catch(function() { return null; }),
            getFallbackTemp(),
            fs.trimmed('/etc/argon_version').catch(function() { return 'unknown'; }),
            fs.read_direct('/etc/config/argononev3').catch(function() { return null; })
        ]);
    },

    render: function(data) {
        var installedVersion = data[3] || 'unknown';
        var configRaw = data[4] || '';

        // ==============================================================================
        // DASHBOARD HTML
        // ==============================================================================
        var dashboardHtml = 
            '<div style="background:#1e293b;color:#f8fafc;border-left:5px solid #3b82f6;padding:18px;margin-bottom:25px;border-radius:6px;box-shadow:0 4px 6px rgba(0,0,0,0.3);font-family:sans-serif;">' +
                '<h4 style="margin-top:0;color:#f8fafc;font-weight:bold;border-bottom:1px solid #334155;padding-bottom:10px;">' +
                    'Live Telemetry <span id="argon_spin" style="font-size:13px;color:#ef4444;margin-left:10px;text-shadow:0 0 8px rgba(239,68,68,0.6);">&#9679; Live</span>' +
                '</h4>' +
                '<table style="width:100%;max-width:550px;font-size:14px;margin-top:10px;">' +
                    '<tr><td style="padding:5px 0;color:#94a3b8;width:45%;"><b>Service Status:</b></td><td style="padding:5px 0;" id="argon_status">...</td></tr>' +
                    '<tr><td style="padding:5px 0;color:#94a3b8;"><b>CPU Temperature:</b></td><td style="padding:5px 0;"><b id="argon_temp">...</b><span id="argon_spark"></span></td></tr>' +
                    '<tr><td style="padding:5px 0;color:#94a3b8;"><b>Peak Temperature:</b></td><td style="padding:5px 0;" id="argon_peak"><span style="color:#64748b;">...</span></td></tr>' +
                    '<tr><td style="padding:5px 0;color:#94a3b8;"><b>Active Mode:</b></td><td style="padding:5px 0;" id="argon_mode">...</td></tr>' +
                    '<tr><td style="padding:5px 0;color:#94a3b8;"><b>Fan Speed:</b></td><td style="padding:5px 0;" id="argon_speed">...</td></tr>' +
                    '<tr><td style="padding:5px 0;color:#94a3b8;"><b>Daemon Uptime:</b></td><td style="padding:5px 0;" id="argon_uptime"><span style="color:#64748b;">...</span></td></tr>' +
                    '<tr><td style="padding:5px 0;color:#94a3b8;"><b>I2C Bus:</b></td><td style="padding:5px 0;" id="argon_i2c"><span style="color:#64748b;">...</span></td></tr>' +
                '</table>' +
                '<div style="margin-top:12px;padding-top:10px;border-top:1px solid #334155;display:flex;gap:8px;align-items:center;flex-wrap:wrap;">' +
                    '<button id="argon_fan_test" class="cbi-button" style="font-size:13px;padding:4px 14px;">&#9654; Fan Test</button>' +
                    '<button id="argon_svc_restart" class="cbi-button" style="font-size:13px;padding:4px 14px;">&#8635; Restart Daemon</button>' +
                    '<span id="argon_fan_test_status" style="margin-left:6px;font-size:13px;color:#94a3b8;"></span>' +
                '</div>' +
            '</div>';

        var m, s, o;

        m = new form.Map('argononev3', _('Argon ONE V3 Fan Control'), dashboardHtml + _('Configure the Argon ONE V3 cooling fan settings easily using the tabs below.'));

        s = m.section(form.NamedSection, 'config', 'global', _('Configuration'));
        s.addremove = false;

        s.tab('general', _('General'), _('Basic operation, manual control and logging settings.'));
        s.tab('curve', _('Cooling Curve'), _('Dynamic temperature thresholds, fan speeds, and hysteresis.'));
        s.tab('night', _('Night Mode'), _('Quiet hours scheduling to limit fan noise.'));
        s.tab('safety', _('Safety'), _('Critical thermal shutdown protection.'));
        s.tab('about', _('About & Updates'), _('Project information and software updates.'));

        // ==========================================
        // TAB 1: GENERAL
        // ==========================================
        o = s.taboption('general', form.Flag, 'enabled', _('Enable Service'), _('Start or stop the background fan daemon on boot.'));
        o.rmempty = false;

        o = s.taboption('general', form.ListValue, 'mode', _('Operation Mode'), _('Select whether the fan runs automatically based on temperature, or at a fixed manual speed.'));
        o.value('auto', _('Auto (Temperature Based)'));
        o.value('manual', _('Manual (Fixed Speed)'));
        o.default = 'auto';

        o = s.taboption('general', form.Value, 'manual_speed', _('Manual Fan Speed'), _('Use the slider to set the fixed fan speed when Manual mode is active.'));
        o.depends('mode', 'manual');
        o.datatype = 'range(0, 100)';
        o.default = '50';
        
        o.renderWidget = function(section_id, option_index, cfgvalue) {
            var value = (cfgvalue != null) ? cfgvalue : this.default;
            var sliderId = this.cbid(section_id) + '_slider';
            var rangeInput = E('input', {
                'type': 'range', 'min': '0', 'max': '100', 'step': '1', 'value': value, 'id': sliderId,
                'style': 'vertical-align:middle;margin-right:15px;width:100%;max-width:300px;cursor:pointer;accent-color:#3b82f6;'
            });
            var valueDisplay = E('span', { 'style': 'font-weight:bold;vertical-align:middle;min-width:50px;display:inline-block;' }, value + ' %');
            rangeInput.addEventListener('input', function(ev) { valueDisplay.textContent = ev.target.value + ' %'; });
            return E('div', { 'style': 'display:flex;align-items:center;' }, [ rangeInput, valueDisplay ]);
        };
        o.formvalue = function(section_id) {
            var el = document.getElementById(this.cbid(section_id) + '_slider');
            return el ? el.value : null;
        };

        o = s.taboption('general', form.ListValue, 'log_level', _('Logging Level'), _('Controls how much information is written to the system log (logread).'));
        o.value('1', _('Verbose (Info & Errors)'));
        o.value('0', _('Quiet (Errors Only)'));
        o.default = '1';

        // ==========================================
        // TAB 2: COOLING CURVE + PRESETS
        // ==========================================

        // Preset selector (DummyValue with buttons rendered post-render)
        o = s.taboption('curve', form.DummyValue, '_presets');
        o.rawhtml = true;
        o.depends('mode', 'auto');
        o.cfgvalue = function() {
            return '<div style="margin-bottom:15px;padding:12px;background:#1e293b;border-radius:6px;border-left:4px solid #8b5cf6;">' +
                   '<b style="color:#f8fafc;font-size:14px;">Quick Presets:</b>' +
                   '<div style="margin-top:8px;display:flex;gap:8px;flex-wrap:wrap;">' +
                   '<button id="preset_silent" class="cbi-button" style="font-size:13px;padding:5px 16px;" title="Higher thresholds, lower speeds. Minimal fan noise.">&#128264; Silent</button>' +
                   '<button id="preset_balanced" class="cbi-button cbi-button-apply" style="font-size:13px;padding:5px 16px;" title="Optimized for RPi 5 daily use. Good balance of cooling and noise.">&#9878; Balanced</button>' +
                   '<button id="preset_performance" class="cbi-button cbi-button-action" style="font-size:13px;padding:5px 16px;" title="Aggressive cooling. Fan kicks in early and runs faster.">&#9889; Performance</button>' +
                   '</div>' +
                   '<p style="color:#94a3b8;font-size:12px;margin:8px 0 0 0;">Presets fill the fields below. Review and click <b>Save &amp; Apply</b> to activate.</p>' +
                   '</div>';
        };

        o = s.taboption('curve', form.Value, 'temp_high', _('High Temp Threshold (°C)'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '72';
        o.validate = function(section_id, value) {
            var tH = parseInt(value, 10);
            var tM = parseInt(this.map.lookupOption('temp_med', section_id)[0].formvalue(section_id), 10);
            if (!isNaN(tH) && !isNaN(tM) && tH <= tM) return _('High must be greater than Medium (%d°C).').format(tM);
            return true;
        };
        
        o = s.taboption('curve', form.Value, 'speed_high', _('High Fan Speed (%)'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '100';

        o = s.taboption('curve', form.Value, 'temp_med', _('Medium Temp Threshold (°C)'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '65';
        o.validate = function(section_id, value) {
            var tM = parseInt(value, 10);
            var tL = parseInt(this.map.lookupOption('temp_low', section_id)[0].formvalue(section_id), 10);
            if (!isNaN(tM) && !isNaN(tL) && tM <= tL) return _('Medium must be greater than Low (%d°C).').format(tL);
            return true;
        };
        
        o = s.taboption('curve', form.Value, 'speed_med', _('Medium Fan Speed (%)'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '75';

        o = s.taboption('curve', form.Value, 'temp_low', _('Low Temp Threshold (°C)'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '58';
        o.validate = function(section_id, value) {
            var tL = parseInt(value, 10);
            var tQ = parseInt(this.map.lookupOption('temp_quiet', section_id)[0].formvalue(section_id), 10);
            if (!isNaN(tL) && !isNaN(tQ) && tL <= tQ) return _('Low must be greater than Quiet (%d°C).').format(tQ);
            return true;
        };
        
        o = s.taboption('curve', form.Value, 'speed_low', _('Low Fan Speed (%)'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '50';

        o = s.taboption('curve', form.Value, 'temp_quiet', _('Quiet Temp Threshold (°C)'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '50';
        
        o = s.taboption('curve', form.Value, 'speed_quiet', _('Quiet Fan Speed (%)'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '25';

        o = s.taboption('curve', form.Value, 'hysteresis', _('Hysteresis (°C)'), _('Temperature drop required below a threshold before reducing fan speed.'));
        o.depends('mode', 'auto'); o.datatype = 'range(1, 10)'; o.default = '3';

        // ==========================================
        // TAB 3: NIGHT MODE
        // ==========================================
        o = s.taboption('night', form.Flag, 'night_enabled', _('Enable Night Mode'), _('Caps the maximum fan speed during designated night hours. Thermal Shutdown safely overrides this if needed.'));
        o.rmempty = false;

        o = s.taboption('night', form.ListValue, 'night_start', _('Night Mode Start Hour'));
        o.depends('night_enabled', '1');
        for (var i = 0; i < 24; i++) { var hs = (i<10?'0':'')+i; o.value(hs, hs + ':00'); }
        o.default = '23';

        o = s.taboption('night', form.ListValue, 'night_end', _('Night Mode End Hour'));
        o.depends('night_enabled', '1');
        for (var j = 0; j < 24; j++) { var hs2 = (j<10?'0':'')+j; o.value(hs2, hs2 + ':00'); }
        o.default = '07';

        o = s.taboption('night', form.Value, 'night_max', _('Maximum Night Speed (%)'));
        o.depends('night_enabled', '1');
        o.datatype = 'range(0, 100)';
        o.default = '30';

        // ==========================================
        // TAB 4: SAFETY
        // ==========================================
        o = s.taboption('safety', form.Flag, 'shutdown_enabled', _('Critical Thermal Shutdown'), _('Safely power off the device if the temperature exceeds the critical limit to prevent hardware damage.'));
        o.rmempty = false;

        o = s.taboption('safety', form.Value, 'shutdown_temp', _('Shutdown Temperature (°C)'), _('If reached 3 consecutive times (~15s), the system will halt.'));
        o.depends('shutdown_enabled', '1');
        o.datatype = 'range(70, 95)';
        o.default = '85';
        o.validate = function(section_id, value) {
            var sT = parseInt(value, 10);
            var tH = parseInt(this.map.lookupOption('temp_high', section_id)[0].formvalue(section_id), 10);
            if (!isNaN(sT) && !isNaN(tH) && sT <= tH) return _('Shutdown temp must be above High threshold (%d°C).').format(tH);
            return true;
        };

        // ==========================================
        // TAB 5: ABOUT & UPDATES
        // ==========================================
        o = s.taboption('about', form.DummyValue, '_about_info');
        o.rawhtml = true;
        o.cfgvalue = function() {
            return '<div style="padding:15px;background:#1e293b;border-radius:6px;color:#f8fafc;border-left:5px solid #10b981;margin-bottom:20px;">' +
                   '<h3 style="color:#f8fafc;margin-top:0;">Argon ONE V3 Fan Control</h3>' +
                   '<p style="color:#cbd5e1;font-size:14px;line-height:1.6;">Professional LuCI interface and lightweight daemon for managing the Argon ONE V3 cooling fan natively on OpenWrt.</p>' +
                   '<table style="width:100%;max-width:600px;font-size:14px;margin-top:15px;">' +
                   '<tr><td style="padding:4px 0;color:#94a3b8;width:160px;"><b>Installed Version:</b></td><td style="padding:4px 0;"><span id="argon_ver" style="color:#38bdf8;font-weight:bold;font-size:15px;">' + installedVersion + '</span></td></tr>' +
                   '<tr><td style="padding:4px 0;color:#94a3b8;"><b>Author:</b></td><td style="padding:4px 0;">ciwga</td></tr>' +
                   '<tr><td style="padding:4px 0;color:#94a3b8;"><b>GitHub:</b></td><td style="padding:4px 0;"><a href="https://github.com/ciwga/luci-app-argononev3-fancontrol" target="_blank" rel="noopener noreferrer" style="color:#38bdf8;text-decoration:none;">ciwga/luci-app-argononev3-fancontrol</a></td></tr>' +
                   '<tr><td style="padding:4px 0;color:#94a3b8;"><b>License:</b></td><td style="padding:4px 0;">MIT</td></tr>' +
                   '</table>' +
                   '<hr style="border:0;border-top:1px solid #334155;margin:20px 0;"/>' +
                   '<div style="display:flex;align-items:center;flex-wrap:wrap;gap:10px;">' +
                   '<button id="argon_update_btn" class="cbi-button cbi-button-apply">Check for Updates</button>' +
                   '<span id="argon_update_status" style="font-size:14px;font-weight:bold;color:#94a3b8;">Click to check...</span>' +
                   '</div>' +
                   '<hr style="border:0;border-top:1px solid #334155;margin:20px 0;"/>' +
                   '<div style="display:flex;gap:10px;flex-wrap:wrap;">' +
                   '<button id="argon_export_btn" class="cbi-button" style="font-size:13px;">&#128190; Export Config</button>' +
                   '<label class="cbi-button" style="font-size:13px;cursor:pointer;">&#128194; Import Config<input type="file" id="argon_import_file" accept=".json" style="display:none;"></label>' +
                   '<span id="argon_io_status" style="font-size:13px;color:#94a3b8;align-self:center;"></span>' +
                   '</div>' +
                   '</div>';
        };

        var renderPromise = m.render();

        renderPromise.then(function(node) {

            // ==============================================================
            // PRESET BUTTONS: Fill form fields with preset values
            // ==============================================================
            var applyPreset = function(presetName) {
                var p = PRESETS[presetName];
                if (!p) return;
                var fields = ['temp_high','speed_high','temp_med','speed_med','temp_low','speed_low','temp_quiet','speed_quiet','hysteresis'];
                for (var i = 0; i < fields.length; i++) {
                    var el = node.querySelector('[id*="widget.cbid.argononev3.config.' + fields[i] + '"]') ||
                             node.querySelector('input[data-name="' + fields[i] + '"]');
                    if (!el) {
                        // Try LuCI's standard id pattern
                        var inputs = node.querySelectorAll('input[type="text"], select');
                        for (var k = 0; k < inputs.length; k++) {
                            if (inputs[k].id && inputs[k].id.indexOf(fields[i]) !== -1) {
                                el = inputs[k]; break;
                            }
                        }
                    }
                    if (el) {
                        el.value = p[fields[i]];
                        // Trigger LuCI's change detection
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                }
            };

            ['silent', 'balanced', 'performance'].forEach(function(name) {
                var btn = node.querySelector('#preset_' + name);
                if (btn) btn.addEventListener('click', function(ev) { ev.preventDefault(); applyPreset(name); });
            });

            // ==============================================================
            // FAN TEST: Calls the dedicated confined /usr/bin/argon_fan_test.sh
            // This script reads the daemon PID and sends SIGUSR1 safely.
            // ACL grants exec on this specific script only (no /bin/sh needed).
            // Rate-limited: button disabled for 8 seconds after each test.
            // ==============================================================
            var fanTestBtn = node.querySelector('#argon_fan_test');
            if (fanTestBtn) {
                fanTestBtn.addEventListener('click', function(ev) {
                    ev.preventDefault();
                    var st = node.querySelector('#argon_fan_test_status');
                    fanTestBtn.disabled = true;
                    st.innerHTML = '<span style="color:#f59e0b;">Sending fan test signal...</span>';
                    
                    fs.exec('/usr/bin/argon_fan_test.sh').then(function(res) {
                        if (res && res.code === 0) {
                            st.innerHTML = '<span style="color:#10b981;">&#10004; Fan running at 100% for 3 seconds.</span>';
                        } else {
                            st.innerHTML = '<span style="color:#ef4444;">Daemon not running (exit: ' + (res ? res.code : '?') + ').</span>';
                        }
                        // Rate limit: re-enable after 8 seconds (test is 3s + margin)
                        setTimeout(function() { fanTestBtn.disabled = false; st.textContent = ''; }, 8000);
                    }).catch(function() {
                        st.innerHTML = '<span style="color:#ef4444;">RPC denied. Check ACL for argon_fan_test.sh.</span>';
                        setTimeout(function() { fanTestBtn.disabled = false; st.textContent = ''; }, 5000);
                    });
                });
            }

            // ==============================================================
            // SERVICE RESTART: Restart daemon via init.d (uses fs.exec)
            // Uses the same confined approach - calls init script directly.
            // ==============================================================
            var restartBtn = node.querySelector('#argon_svc_restart');
            if (restartBtn) {
                restartBtn.addEventListener('click', function(ev) {
                    ev.preventDefault();
                    var st = node.querySelector('#argon_fan_test_status');
                    if (!confirm(_('Restart the fan daemon? Fan will briefly stop during restart.'))) return;
                    restartBtn.disabled = true;
                    st.innerHTML = '<span style="color:#f59e0b;">Restarting daemon...</span>';
                    fs.exec('/etc/init.d/argon_daemon', ['restart']).then(function(res) {
                        if (res && res.code === 0) {
                            st.innerHTML = '<span style="color:#10b981;">&#10004; Daemon restarted.</span>';
                        } else {
                            st.innerHTML = '<span style="color:#ef4444;">Restart failed (code ' + (res ? res.code : '?') + ').</span>';
                        }
                        setTimeout(function() { restartBtn.disabled = false; st.textContent = ''; }, 5000);
                    }).catch(function() {
                        st.innerHTML = '<span style="color:#ef4444;">RPC error.</span>';
                        setTimeout(function() { restartBtn.disabled = false; st.textContent = ''; }, 3000);
                    });
                });
            }

            // ==============================================================
            // UPDATE BUTTON: Version-aware OTA
            // ==============================================================
            var updateBtn = node.querySelector('#argon_update_btn');
            if (updateBtn) {
                updateBtn.addEventListener('click', function(ev) {
                    ev.preventDefault();
                    var st = node.querySelector('#argon_update_status');
                    updateBtn.disabled = true;
                    st.innerHTML = '<span style="color:#f59e0b;">Checking GitHub...</span>';
                    
                    fetch('https://api.github.com/repos/ciwga/luci-app-argononev3-fancontrol/releases/latest')
                    .then(function(r) { return r.json(); })
                    .then(function(gh) {
                        updateBtn.disabled = false;
                        var tag = gh.tag_name || gh.name;
                        if (!tag) { st.innerHTML = '<span style="color:#ef4444;">Parse error.</span>'; return; }

                        var nR = tag.replace(/^[vV]/, ''), nL = installedVersion.replace(/^[vV]/, '');
                        if (nL !== 'unknown' && nL.indexOf(nR) === 0) {
                            st.innerHTML = '<span style="color:#10b981;">&#10004; Up-to-date</span> <span style="color:#94a3b8;">(' + installedVersion + ' = ' + tag + ')</span>';
                            return;
                        }

                        st.innerHTML = '<span style="color:#f59e0b;">&#9650; ' + installedVersion + ' &#8594; ' + tag + '</span>';
                        if (confirm('Update: ' + installedVersion + ' -> ' + tag + '\n\nInstall now?')) {
                            updateBtn.disabled = true;
                            st.innerHTML = '<span style="color:#c084fc;">Installing ' + tag + '...</span>';
                            fs.exec('/usr/bin/argon_update.sh').then(function(res) {
                                updateBtn.disabled = false;
                                if (res.code === 0) st.innerHTML = '<span style="color:#10b981;">&#10004; Done! Refresh page.</span>';
                                else if (res.code === 2) st.innerHTML = '<span style="color:#10b981;">&#10004; Already up-to-date.</span>';
                                else st.innerHTML = '<span style="color:#ef4444;">Failed (code ' + res.code + '). logread -e argon_updater</span>';
                            }).catch(function() { updateBtn.disabled = false; st.innerHTML = '<span style="color:#ef4444;">RPC/ACL blocked.</span>'; });
                        }
                    })
                    .catch(function() { updateBtn.disabled = false; st.innerHTML = '<span style="color:#ef4444;">Network error.</span>'; });
                });
            }

            // ==============================================================
            // CONFIG EXPORT: Download UCI config as JSON
            // ==============================================================
            var exportBtn = node.querySelector('#argon_export_btn');
            if (exportBtn) {
                exportBtn.addEventListener('click', function(ev) {
                    ev.preventDefault();
                    var ioSt = node.querySelector('#argon_io_status');
                    
                    // Read current UCI values via the form map
                    fs.read_direct('/etc/config/argononev3').then(function(raw) {
                        if (!raw) { ioSt.innerHTML = '<span style="color:#ef4444;">Config not found.</span>'; return; }
                        
                        // Parse UCI format into JSON
                        var cfg = {};
                        var lines = raw.split('\n');
                        for (var i = 0; i < lines.length; i++) {
                            var match = lines[i].match(/^\s*option\s+(\S+)\s+'([^']*)'/);
                            if (match) cfg[match[1]] = match[2];
                        }
                        cfg._exported = new Date().toISOString();
                        cfg._version = installedVersion;
                        
                        var blob = new Blob([JSON.stringify(cfg, null, 2)], { type: 'application/json' });
                        var a = document.createElement('a');
                        a.href = URL.createObjectURL(blob);
                        a.download = 'argononev3-config-' + (installedVersion || 'backup') + '.json';
                        a.click();
                        URL.revokeObjectURL(a.href);
                        ioSt.innerHTML = '<span style="color:#10b981;">&#10004; Exported!</span>';
                        setTimeout(function() { ioSt.textContent = ''; }, 3000);
                    }).catch(function() {
                        ioSt.innerHTML = '<span style="color:#ef4444;">Read error.</span>';
                    });
                });
            }

            // ==============================================================
            // CONFIG IMPORT: Upload JSON, apply via UCI
            // ==============================================================
            var importInput = node.querySelector('#argon_import_file');
            if (importInput) {
                importInput.addEventListener('change', function(ev) {
                    var ioSt = node.querySelector('#argon_io_status');
                    var file = ev.target.files[0];
                    if (!file) return;
                    
                    var reader = new FileReader();
                    reader.onload = function(e) {
                        try {
                            var cfg = JSON.parse(e.target.result);
                            // Whitelist of safe UCI option names (no arbitrary keys)
                            var allowed = ['enabled','mode','manual_speed','log_level',
                                'temp_high','speed_high','temp_med','speed_med','temp_low','speed_low',
                                'temp_quiet','speed_quiet','hysteresis',
                                'night_enabled','night_start','night_end','night_max',
                                'shutdown_enabled','shutdown_temp'];
                            
                            var applied = 0;
                            for (var k = 0; k < allowed.length; k++) {
                                var key = allowed[k];
                                if (cfg[key] !== undefined) {
                                    // Sanitize value: only allow safe characters
                                    var val = String(cfg[key]).replace(/[^a-zA-Z0-9._-]/g, '');
                                    uci.set('argononev3', 'config', key, val);
                                    applied++;
                                }
                            }
                            
                            // Validate threshold ordering before saving
                            var tQ = parseInt(cfg.temp_quiet || '0', 10), tL = parseInt(cfg.temp_low || '0', 10),
                                tM = parseInt(cfg.temp_med || '0', 10), tH = parseInt(cfg.temp_high || '0', 10);
                            if (tQ > 0 && tL > 0 && tM > 0 && tH > 0 && !(tQ < tL && tL < tM && tM < tH)) {
                                ioSt.innerHTML = '<span style="color:#ef4444;">Import rejected: thresholds must be Quiet &lt; Low &lt; Med &lt; High.</span>';
                                uci.unload('argononev3');
                                ev.target.value = '';
                                return;
                            }
                            
                            if (applied > 0) {
                                uci.save();
                                ioSt.innerHTML = '<span style="color:#10b981;">&#10004; ' + applied + ' settings imported. Click Save &amp; Apply.</span>';
                                // Refresh the form to show new values
                                window.setTimeout(function() { window.location.reload(); }, 1500);
                            } else {
                                ioSt.innerHTML = '<span style="color:#f59e0b;">No valid settings found.</span>';
                            }
                        } catch (err) {
                            ioSt.innerHTML = '<span style="color:#ef4444;">Invalid JSON file.</span>';
                        }
                        // Reset input so same file can be re-imported
                        ev.target.value = '';
                    };
                    reader.readAsText(file);
                });
            }

            // ==============================================================
            // LIVE DASHBOARD POLLER (3s interval, self-cleaning)
            // ==============================================================
            var updateDashboard = function() {
                Promise.all([
                    callServiceList('argon_daemon').catch(function() { return {}; }),
                    fs.read_direct('/var/run/argon_fan.status').catch(function() { return null; }),
                    fs.trimmed('/sys/class/thermal/thermal_zone0/temp').catch(function() { return '0'; })
                ]).then(function(res) {
                    var cSrv = res[0], cStatus = res[1], cTempRaw = res[2];

                    var isRun = !!(cSrv && cSrv['argon_daemon'] && cSrv['argon_daemon'].instances && Object.keys(cSrv['argon_daemon'].instances).length > 0);

                    var tData = {};
                    if (cStatus) { try { tData = JSON.parse(cStatus); } catch(e) {} }

                    var aMode = tData.mode ? tData.mode.toUpperCase() : 'UNKNOWN';
                    var aLevel = tData.level !== undefined ? tData.level : -1;
                    var actSpeed = tData.active_speed !== undefined ? tData.active_speed : 0;
                    var dTemp = tData.temp !== undefined ? tData.temp : Math.floor(parseInt(cTempRaw, 10) / 1000);
                    var isNight = tData.night !== undefined ? tData.night : 0;
                    var dUptime = tData.uptime !== undefined ? tData.uptime : 0;
                    var dPeak = tData.peak !== undefined ? tData.peak : 0;
                    var dBus = tData.i2c_bus || '';
                    var dNightEnd = tData.night_end || '';

                    if (dTemp > 0) pushTemp(dTemp);

                    // Fan speed label
                    var lText = '<span style="color:#64748b;">N/A</span>';
                    if (aMode === 'MANUAL') {
                        lText = '<b style="color:#38bdf8;">' + actSpeed + '%</b> <span style="color:#cbd5e1;">(Manual)</span>';
                    } else {
                        var labels = ['Off', 'Quiet', 'Low', 'Medium', 'High'];
                        var colors = ['#cbd5e1', '#38bdf8', '#3b82f6', '#818cf8', '#f43f5e'];
                        if (aLevel >= 0 && aLevel <= 4) {
                            lText = '<b style="color:' + colors[aLevel] + ';">' + actSpeed + '%</b> <span style="color:#cbd5e1;">(' + labels[aLevel] + ')</span>';
                        }
                    }
                    if (isNight === 1) {
                        var endLabel = dNightEnd ? ' until ' + dNightEnd + ':00' : '';
                        lText += ' <span style="color:#c084fc;font-weight:bold;margin-left:8px;">&#127769; Night' + endLabel + '</span>';
                    }

                    var sHtml = isRun 
                        ? '<span style="color:#22c55e;font-weight:bold;">&#10004; Running</span>' 
                        : '<span style="color:#ef4444;font-weight:bold;">&#10008; Stopped</span>';

                    if (!isRun) {
                        aMode = '<span style="color:#64748b;">Offline</span>';
                        lText = '<span style="color:#64748b;">Offline</span>';
                    } else {
                        aMode = '<span style="color:#e2e8f0;font-weight:bold;">' + aMode + '</span>';
                    }

                    var el = function(id) { return document.getElementById(id); };

                    if (el('argon_status')) el('argon_status').innerHTML = sHtml;
                    if (el('argon_temp')) {
                        var tc;
                        if (dTemp >= 80) tc = '<span style="color:#ef4444;text-shadow:0 0 5px #ef4444;">' + dTemp + ' °C (CRITICAL)</span>';
                        else if (dTemp >= 60) tc = '<span style="color:#f59e0b;">' + dTemp + ' °C</span>';
                        else tc = '<span style="color:#f8fafc;">' + dTemp + ' °C</span>';
                        el('argon_temp').innerHTML = tc;
                    }
                    if (el('argon_spark')) el('argon_spark').innerHTML = sparkSvg(_tHist);
                    if (el('argon_peak')) {
                        var pc = dPeak >= 80 ? '#ef4444' : (dPeak >= 60 ? '#f59e0b' : '#94a3b8');
                        el('argon_peak').innerHTML = isRun ? '<span style="color:' + pc + ';">' + dPeak + ' °C</span> <span style="color:#64748b;font-size:12px;">(since daemon start)</span>' : '<span style="color:#64748b;">Offline</span>';
                    }
                    if (el('argon_mode')) el('argon_mode').innerHTML = aMode;
                    if (el('argon_speed')) el('argon_speed').innerHTML = lText;
                    if (el('argon_uptime')) {
                        el('argon_uptime').innerHTML = isRun && dUptime > 0 
                            ? '<span style="color:#e2e8f0;">' + formatUptime(dUptime) + '</span>' 
                            : '<span style="color:#64748b;">' + (isRun ? 'Starting...' : 'Offline') + '</span>';
                    }
                    if (el('argon_i2c')) {
                        el('argon_i2c').innerHTML = isRun && dBus
                            ? '<span style="color:#e2e8f0;">/dev/i2c-' + dBus + '</span> <span style="color:#64748b;font-size:12px;">(0x1a)</span>'
                            : '<span style="color:#64748b;">' + (isRun ? 'Detecting...' : 'Offline') + '</span>';
                    }
                });
            };

            var intervalId = window.setInterval(function() {
                if (!document.getElementById('argon_status')) {
                    window.clearInterval(intervalId);
                    _tHist = [];
                    return;
                }
                updateDashboard();
            }, 3000);
        });

        return renderPromise;
    }
});