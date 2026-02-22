'use strict';
'require view';
'require form';
'require fs';
'require rpc';

var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: [ 'name' ],
    expect: { '': {} }
});

return view.extend({
    load: function() {
        var getFallbackTemp = function() {
            return fs.trimmed('/sys/class/thermal/thermal_zone0/temp').catch(function() {
                return fs.trimmed('/sys/class/thermal/thermal_zone1/temp').catch(function() {
                    return '0';
                });
            });
        };

        return Promise.all([
            callServiceList('argon_daemon').catch(function() { return {}; }),
            fs.read_direct('/var/run/argon_fan.status').catch(function() { return null; }),
            getFallbackTemp()
        ]);
    },

    render: function(data) {
        var dashboardHtml = 
            '<div style="background: #1e293b; color: #f8fafc; border-left: 5px solid #3b82f6; padding: 18px; margin-bottom: 25px; border-radius: 6px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); font-family: sans-serif;">' +
                '<h4 style="margin-top: 0; color: #f8fafc; font-weight: bold; border-bottom: 1px solid #334155; padding-bottom: 10px;">' +
                    'Live Telemetry <span id="argon_spin" style="font-size: 13px; color: #ef4444; margin-left: 10px; text-shadow: 0 0 8px rgba(239, 68, 68, 0.6);">◉ Live</span>' +
                '</h4>' +
                '<table style="width: 100%; max-width: 500px; font-size: 14px; margin-top: 10px;">' +
                    '<tr><td style="padding: 6px 0; color: #94a3b8; width: 45%;"><b>Service Status:</b></td><td style="padding: 6px 0;" id="argon_status">...</td></tr>' +
                    '<tr><td style="padding: 6px 0; color: #94a3b8;"><b>Current CPU Temp:</b></td><td style="padding: 6px 0;"><b id="argon_temp">...</b></td></tr>' +
                    '<tr><td style="padding: 6px 0; color: #94a3b8;"><b>Active Daemon Mode:</b></td><td style="padding: 6px 0;" id="argon_mode">...</td></tr>' +
                    '<tr><td style="padding: 6px 0; color: #94a3b8;"><b>Current Fan Speed:</b></td><td style="padding: 6px 0;" id="argon_speed">...</td></tr>' +
                '</table>' +
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
        o.default = '55';
        
        o.renderWidget = function(section_id, option_index, cfgvalue) {
            var value = (cfgvalue != null) ? cfgvalue : this.default;
            var sliderId = this.cbid(section_id) + '_slider';
            
            var rangeInput = E('input', {
                'type': 'range',
                'min': '0',
                'max': '100',
                'step': '1',
                'value': value,
                'id': sliderId,
                'style': 'vertical-align: middle; margin-right: 15px; width: 100%; max-width: 300px; cursor: pointer; accent-color: #3b82f6;'
            });

            var valueDisplay = E('span', { 
                'style': 'font-weight: bold; vertical-align: middle; min-width: 50px; display: inline-block;' 
            }, value + ' %');

            rangeInput.addEventListener('input', function(ev) {
                valueDisplay.textContent = ev.target.value + ' %';
            });

            return E('div', { 'style': 'display: flex; align-items: center;' }, [ rangeInput, valueDisplay ]);
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
        // TAB 2: COOLING CURVE
        // ==========================================
        o = s.taboption('curve', form.Value, 'temp_high', _('High Temp Threshold (°C)'), _('Triggers the High Fan Speed profile.'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '60';
        
        o = s.taboption('curve', form.Value, 'speed_high', _('High Fan Speed (%)'), _('Speed percentage for the High Temp threshold.'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '100';

        o = s.taboption('curve', form.Value, 'temp_med', _('Medium Temp Threshold (°C)'), _('Triggers the Medium Fan Speed profile.'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '55';
        
        o = s.taboption('curve', form.Value, 'speed_med', _('Medium Fan Speed (%)'), _('Speed percentage for the Medium Temp threshold.'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '55';

        o = s.taboption('curve', form.Value, 'temp_low', _('Low Temp Threshold (°C)'), _('Triggers the Low Fan Speed profile.'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '45';
        
        o = s.taboption('curve', form.Value, 'speed_low', _('Low Fan Speed (%)'), _('Speed percentage for the Low Temp threshold.'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '25';

        o = s.taboption('curve', form.Value, 'temp_quiet', _('Quiet Temp Threshold (°C)'), _('Triggers the Quiet Fan Speed profile.'));
        o.depends('mode', 'auto'); o.datatype = 'range(30, 90)'; o.default = '40';
        
        o = s.taboption('curve', form.Value, 'speed_quiet', _('Quiet Fan Speed (%)'), _('Speed percentage for the Quiet Temp threshold.'));
        o.depends('mode', 'auto'); o.datatype = 'range(0, 100)'; o.default = '10';

        o = s.taboption('curve', form.Value, 'hysteresis', _('Hysteresis (°C)'), _('Temperature drop required below a threshold before reducing fan speed. Prevents rapid speed cycling.'));
        o.depends('mode', 'auto'); o.datatype = 'range(1, 10)'; o.default = '4';

        // ==========================================
        // TAB 3: NIGHT MODE
        // ==========================================
        o = s.taboption('night', form.Flag, 'night_enabled', _('Enable Night Mode'), _('Caps the maximum fan speed during designated night hours. Thermal Shutdown will safely override this if needed.'));
        o.rmempty = false;

        o = s.taboption('night', form.ListValue, 'night_start', _('Night Mode Start Hour'), _('When should quiet hours begin?'));
        o.depends('night_enabled', '1');
        for (var i = 0; i < 24; i++) { var hs = (i<10?'0':'')+i; o.value(hs, hs + ':00'); }
        o.default = '23';

        o = s.taboption('night', form.ListValue, 'night_end', _('Night Mode End Hour'), _('When should quiet hours end?'));
        o.depends('night_enabled', '1');
        for (var j = 0; j < 24; j++) { var hs2 = (j<10?'0':'')+j; o.value(hs2, hs2 + ':00'); }
        o.default = '07';

        o = s.taboption('night', form.Value, 'night_max', _('Maximum Night Speed (%)'), _('The absolute maximum fan speed allowed during Night Mode.'));
        o.depends('night_enabled', '1');
        o.datatype = 'range(0, 100)';
        o.default = '25';

        // ==========================================
        // TAB 4: SAFETY
        // ==========================================
        o = s.taboption('safety', form.Flag, 'shutdown_enabled', _('Critical Thermal Shutdown'), _('Safely power off the device if the temperature exceeds the critical limit to prevent hardware damage.'));
        o.rmempty = false;

        o = s.taboption('safety', form.Value, 'shutdown_temp', _('Shutdown Temperature (°C)'), _('Set the critical temperature limit. If reached 3 consecutive times, the system will halt.'));
        o.depends('shutdown_enabled', '1');
        o.datatype = 'range(70, 95)';
        o.default = '85';

        // ==========================================
        // TAB 5: ABOUT & UPDATES
        // ==========================================
        o = s.taboption('about', form.DummyValue, '_about_info');
        o.rawhtml = true;
        o.cfgvalue = function() {
            return '<div style="padding: 15px; background: #1e293b; border-radius: 6px; color: #f8fafc; border-left: 5px solid #10b981; margin-bottom: 20px;">' +
                   '<h3 style="color: #f8fafc; margin-top: 0;">Argon ONE V3 Fan Control</h3>' +
                   '<p style="color: #cbd5e1; font-size: 14px; line-height: 1.6;">A professional, production-grade LuCI interface and lightweight background daemon designed for securely managing the Argon ONE V3 cooling fan natively on OpenWrt without any resource bloat.</p>' +
                   '<table style="width: 100%; max-width: 600px; font-size: 14px; margin-top: 15px;">' +
                   '<tr><td style="padding: 4px 0; color: #94a3b8; width: 120px;"><b>Author:</b></td><td style="padding: 4px 0;">ciwga</td></tr>' +
                   '<tr><td style="padding: 4px 0; color: #94a3b8;"><b>GitHub:</b></td><td style="padding: 4px 0;"><a href="https://github.com/ciwga/luci-app-argononev3-fancontrol" target="_blank" rel="noopener noreferrer" style="color: #38bdf8; text-decoration: none;">ciwga/luci-app-argononev3-fancontrol</a></td></tr>' +
                   '<tr><td style="padding: 4px 0; color: #94a3b8;"><b>License:</b></td><td style="padding: 4px 0;">MIT License</td></tr>' +
                   '</table>' +
                   '<hr style="border: 0; border-top: 1px solid #334155; margin: 20px 0;"/>' +
                   '<div id="argon_update_container" style="display: flex; align-items: center;">' +
                   '<button id="argon_update_btn" class="cbi-button cbi-button-apply" style="margin-right: 15px;">Check for Updates</button>' +
                   '<span id="argon_update_status" style="font-size: 14px; font-weight: bold; color: #94a3b8;">Click to query GitHub for the latest release...</span>' +
                   '</div>' +
                   '</div>';
        };

        var renderPromise = m.render();

        renderPromise.then(function(node) {
            
            // Bypass LuCI CSP: Attach the event listener programmatically after DOM render
            var updateBtn = node.querySelector('#argon_update_btn');
            if (updateBtn) {
                updateBtn.addEventListener('click', function(ev) {
                    ev.preventDefault();
                    var statusEl = node.querySelector('#argon_update_status');
                    statusEl.innerHTML = '<span style="color: #f59e0b;">Checking GitHub API...</span>';
                    
                    fetch('https://api.github.com/repos/ciwga/luci-app-argononev3-fancontrol/releases/latest')
                    .then(function(res) { return res.json(); })
                    .then(function(data) {
                        var latestTag = data.tag_name || data.name;
                        if(latestTag) {
                            statusEl.innerHTML = '<span style="color: #10b981;">Latest release found: ' + latestTag + '</span>';
                            if(confirm('An update check found GitHub release: ' + latestTag + '\n\nDo you want to download and install this update now?\n(The service will securely upgrade and restart automatically)')) {
                                statusEl.innerHTML = '<span style="color: #c084fc;">Downloading and installing... Please wait ~30 seconds, then manually refresh the page.</span>';
                                
                                // Safely execute the restricted shell script using LuCI's fs module
                                fs.exec('/usr/bin/argon_update.sh').then(function(res) {
                                    if(res.code === 0) { 
                                        statusEl.innerHTML = '<span style="color: #10b981;">Update Complete! Please refresh the page.</span>'; 
                                    } else { 
                                        statusEl.innerHTML = '<span style="color: #ef4444;">Update failed. Check system logs (logread).</span>'; 
                                    }
                                }).catch(function(e) { 
                                    statusEl.innerHTML = '<span style="color: #ef4444;">Execution blocked by RPC/ACL policy.</span>'; 
                                });
                            }
                        } else {
                            statusEl.innerHTML = '<span style="color: #ef4444;">Could not parse latest release data.</span>';
                        }
                    })
                    .catch(function(err) {
                        statusEl.innerHTML = '<span style="color: #ef4444;">Network error. Cannot reach GitHub.</span>';
                    });
                });
            }

            var updateDashboard = function() {
                Promise.all([
                    callServiceList('argon_daemon').catch(function() { return {}; }),
                    fs.read_direct('/var/run/argon_fan.status').catch(function() { return null; }),
                    fs.trimmed('/sys/class/thermal/thermal_zone0/temp').catch(function() { return '0'; })
                ]).then(function(res) {
                    var cSrv = res[0];
                    var cStatus = res[1];
                    var cTempRaw = res[2];

                    var isRun = false;
                    if (cSrv && cSrv['argon_daemon'] && cSrv['argon_daemon'].instances && Object.keys(cSrv['argon_daemon'].instances).length > 0) {
                        isRun = true;
                    }

                    var tData = {};
                    if (cStatus) {
                        try { tData = JSON.parse(cStatus); } catch(e) {}
                    }

                    var aMode = tData.mode ? tData.mode.toUpperCase() : 'UNKNOWN';
                    var aLevel = tData.level !== undefined ? tData.level : -1;
                    var actSpeed = tData.active_speed !== undefined ? tData.active_speed : 0;
                    var dTemp = tData.temp !== undefined ? tData.temp : Math.floor(parseInt(cTempRaw, 10) / 1000);
                    var isNight = tData.night !== undefined ? tData.night : 0;

                    var lText = '<span style="color: #64748b;">N/A</span>';
                    
                    if (aMode === 'MANUAL') {
                        lText = '<b style="color: #38bdf8;">' + actSpeed + '%</b> <span style="color: #cbd5e1;">(Fixed Override)</span>';
                    } else {
                        if (aLevel === 0) lText = '<b style="color: #cbd5e1;">0%</b> <span style="color: #64748b;">(Off)</span>';
                        else if (aLevel === 1) lText = '<b style="color: #38bdf8;">' + actSpeed + '%</b> <span style="color: #cbd5e1;">(Quiet)</span>';
                        else if (aLevel === 2) lText = '<b style="color: #3b82f6;">' + actSpeed + '%</b> <span style="color: #cbd5e1;">(Low)</span>';
                        else if (aLevel === 3) lText = '<b style="color: #818cf8;">' + actSpeed + '%</b> <span style="color: #cbd5e1;">(Medium)</span>';
                        else if (aLevel === 4) lText = '<b style="color: #f43f5e;">' + actSpeed + '%</b> <span style="color: #cbd5e1;">(High)</span>';
                    }

                    if (isNight === 1) {
                        lText += ' <span style="color: #c084fc; font-weight: bold; margin-left: 8px;">🌙 (Night Capped)</span>';
                    }

                    var sHtml = isRun 
                        ? '<span style="color: #22c55e; font-weight: bold;">&#10004; Running</span>' 
                        : '<span style="color: #ef4444; font-weight: bold;">&#10008; Stopped</span>';

                    if (!isRun) {
                        aMode = '<span style="color: #64748b;">Service Offline</span>';
                        lText = '<span style="color: #64748b;">Service Offline</span>';
                    } else {
                        aMode = '<span style="color: #e2e8f0; font-weight: bold;">' + aMode + '</span>';
                    }

                    var elStatus = document.getElementById('argon_status');
                    var elTemp = document.getElementById('argon_temp');
                    var elMode = document.getElementById('argon_mode');
                    var elSpeed = document.getElementById('argon_speed');

                    if (elStatus) elStatus.innerHTML = sHtml;
                    if (elTemp) {
                        if (dTemp >= 80) elTemp.innerHTML = '<span style="color: #ef4444; text-shadow: 0 0 5px #ef4444;">' + dTemp + ' °C (CRITICAL)</span>';
                        else if (dTemp >= 60) elTemp.innerHTML = '<span style="color: #f59e0b;">' + dTemp + ' °C</span>';
                        else elTemp.innerHTML = '<span style="color: #f8fafc;">' + dTemp + ' °C</span>';
                    }
                    if (elMode) elMode.innerHTML = aMode;
                    if (elSpeed) elSpeed.innerHTML = lText;
                });
            };

            var intervalId = window.setInterval(function() {
                if (!document.getElementById('argon_status')) {
                    window.clearInterval(intervalId);
                    return;
                }
                updateDashboard();
            }, 3000);
        });

        return renderPromise;
    }
});