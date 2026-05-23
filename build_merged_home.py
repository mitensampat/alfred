#!/usr/bin/env python3
"""
Build script: Merges production home.html with walk-prototype-v3 layout.
Transforms the multi-tab production UI into conversation-first single-view.
"""

import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HOME_HTML = os.path.expanduser('~/.config/alfred/web/home.html')
SOURCE_HTML = os.path.join(SCRIPT_DIR, 'Sources/GUI/Resources/home.html')

# Read the production file
with open(HOME_HTML, 'r') as f:
    content = f.read()

# ============================================================
# 1. UPDATE VERSION to v2.0.6
# ============================================================
content = content.replace('v2.0.4', 'v2.0.6')
content = content.replace("your executive assistant", "sharpen your genius")

# ============================================================
# 2. ADD NEW CSS: conversation-first layout, cmd palette,
#    slide panel, param cards, responsive breakpoints
# ============================================================

new_css = """
        /* ── CONVERSATION-FIRST LAYOUT ── */
        .top-bar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 14px 20px;
            border-bottom: 1px solid var(--line);
            background: var(--canvas);
            flex-shrink: 0;
        }
        .top-bar-title {
            font-family: var(--font-display);
            font-weight: 400;
            font-size: 18px;
            color: var(--ink);
        }
        .top-bar-actions {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .top-bar-btn {
            width: 34px;
            height: 34px;
            border: none;
            background: transparent;
            border-radius: var(--radius-md);
            cursor: pointer;
            font-size: 16px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--ink-secondary);
            transition: background 0.15s;
        }
        .top-bar-btn:hover {
            background: var(--surface-sunken);
        }

        .conversation {
            flex: 1;
            overflow-y: auto;
            padding: 20px 16px 8px;
            scroll-behavior: smooth;
        }
        .conversation-inner {
            max-width: 640px;
            margin: 0 auto;
        }

        /* ── INPUT AREA (conversation-first) ── */
        .input-area {
            padding: 10px 16px max(16px, env(safe-area-inset-bottom, 16px));
            background: var(--canvas);
            border-top: 1px solid var(--line);
            flex-shrink: 0;
        }
        .input-inner {
            max-width: 640px;
            margin: 0 auto;
            position: relative;
        }
        .input-row-v2 {
            display: flex;
            align-items: flex-end;
            gap: 8px;
            background: var(--surface);
            border: 1px solid var(--line);
            border-radius: var(--radius-lg);
            padding: 8px 12px;
            transition: border-color 0.2s;
        }
        .input-row-v2:focus-within {
            border-color: var(--coach);
        }
        .input-row-v2 textarea {
            flex: 1;
            border: none;
            background: transparent;
            font-family: var(--font-body);
            font-size: 14px;
            color: var(--ink);
            resize: none;
            outline: none;
            max-height: 96px;
            line-height: 1.5;
            padding: 4px 0;
        }
        .input-row-v2 textarea::placeholder {
            color: var(--ink-faint);
        }
        .send-btn-v2 {
            width: 32px;
            height: 32px;
            border-radius: 50%;
            border: none;
            background: var(--ink);
            color: var(--canvas);
            display: flex;
            align-items: center;
            justify-content: center;
            cursor: pointer;
            flex-shrink: 0;
            transition: opacity 0.15s;
        }
        .send-btn-v2:hover { opacity: 0.8; }
        .send-btn-v2 svg { width: 16px; height: 16px; }
        [data-theme="dark"] .send-btn-v2 { background: var(--coach); }
        .input-hint {
            text-align: center;
            font-size: 11px;
            color: var(--ink-faint);
            margin-top: 6px;
        }

        /* ── SLASH COMMAND PALETTE ── */
        .cmd-palette {
            position: absolute;
            bottom: 100%;
            left: 0;
            right: 0;
            background: var(--surface);
            border: 1px solid var(--line);
            border-radius: var(--radius-lg);
            box-shadow: var(--shadow-lg);
            padding: 8px 0;
            z-index: 100;
            transform-origin: bottom center;
            animation: paletteSlideUp 0.2s ease-out;
            max-height: 360px;
            overflow-y: auto;
        }
        @keyframes paletteSlideUp {
            from { opacity: 0; transform: translateY(8px); }
            to { opacity: 1; transform: translateY(0); }
        }
        .cmd-palette-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 6px 16px 8px;
            font-size: 10px;
            font-weight: 600;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--ink-tertiary);
            border-bottom: 1px solid var(--line);
            margin-bottom: 4px;
        }
        .cmd-palette-close {
            background: none;
            border: none;
            color: var(--ink-tertiary);
            cursor: pointer;
            font-size: 14px;
            padding: 2px 4px;
        }
        .cmd-item {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 10px 16px;
            cursor: pointer;
            transition: background 0.1s;
        }
        .cmd-item:hover, .cmd-item.active {
            background: var(--coach-light);
        }
        .cmd-item .cmd-icon {
            width: 20px;
            text-align: center;
            font-size: 14px;
            flex-shrink: 0;
        }
        .cmd-item .cmd-name {
            font-weight: 600;
            font-size: 13px;
            color: var(--ink);
            min-width: 100px;
        }
        .cmd-item .cmd-desc {
            font-size: 12px;
            color: var(--ink-tertiary);
        }
        .cmd-no-results {
            padding: 16px;
            text-align: center;
            color: var(--ink-tertiary);
            font-size: 13px;
        }

        /* ── PARAM CARD (inline) ── */
        .param-card {
            background: var(--surface);
            border: 1px solid var(--line);
            border-radius: var(--radius-lg);
            padding: 20px;
            max-width: 400px;
            margin: 8px 0;
            box-shadow: var(--shadow-md);
            animation: fadeIn 0.3s ease-out;
        }
        .param-card h3 {
            font-family: var(--font-display);
            font-weight: 400;
            font-size: 17px;
            margin-bottom: 16px;
            color: var(--ink);
        }
        .param-label {
            font-size: 10px;
            font-weight: 600;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--ink-tertiary);
            margin-bottom: 6px;
            margin-top: 14px;
        }
        .param-label:first-of-type { margin-top: 0; }
        .param-input {
            width: 100%;
            padding: 10px 12px;
            border: 1px solid var(--line);
            border-radius: var(--radius-md);
            font-family: var(--font-body);
            font-size: 13px;
            background: var(--surface-sunken);
            color: var(--ink);
            outline: none;
            transition: border-color 0.2s;
        }
        .param-input:focus { border-color: var(--coach); }
        .param-toggles {
            display: flex;
            gap: 6px;
            flex-wrap: wrap;
        }
        .param-toggle {
            padding: 7px 14px;
            border: 1px solid var(--line);
            border-radius: 20px;
            background: transparent;
            font-family: var(--font-body);
            font-size: 12px;
            color: var(--ink-secondary);
            cursor: pointer;
            transition: all 0.15s;
        }
        .param-toggle.active {
            background: var(--coach);
            color: #fff;
            border-color: var(--coach);
        }
        .param-go-btn {
            width: 100%;
            margin-top: 18px;
            padding: 11px;
            background: var(--ink);
            color: var(--canvas);
            border: none;
            border-radius: var(--radius-md);
            font-family: var(--font-body);
            font-size: 13px;
            font-weight: 500;
            cursor: pointer;
            transition: opacity 0.15s;
        }
        [data-theme="dark"] .param-go-btn { background: var(--coach); color: #fff; }
        .param-go-btn:hover { opacity: 0.85; }

        /* ── SLIDE-UP SETTINGS PANEL ── */
        .panel-overlay {
            position: fixed;
            inset: 0;
            background: var(--surface-overlay);
            z-index: 300;
            display: none;
            animation: fadeIn 0.2s ease both;
        }
        .panel-overlay.open { display: block; }
        .slide-panel {
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            z-index: 400;
            display: none;
        }
        .slide-panel.open { display: block; }
        .slide-panel-inner {
            max-width: 480px;
            margin: 0 auto;
            background: var(--surface);
            border-radius: 20px 20px 0 0;
            box-shadow: var(--shadow-lg);
            max-height: 72vh;
            display: flex;
            flex-direction: column;
            animation: slideUpPanel 0.28s cubic-bezier(0.25, 0.46, 0.45, 0.94) both;
        }
        @keyframes slideUpPanel {
            from { transform: translateY(100%); }
            to { transform: translateY(0); }
        }
        .slide-panel-handle {
            width: 36px;
            height: 4px;
            background: var(--line-strong);
            border-radius: 2px;
            margin: 10px auto 0;
            cursor: pointer;
            flex-shrink: 0;
        }
        .slide-panel-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 14px 18px 10px;
            flex-shrink: 0;
        }
        .slide-panel-title {
            font-family: var(--font-display);
            font-size: 17px;
            font-weight: 400;
            color: var(--ink);
        }
        .slide-panel-close {
            background: var(--surface-sunken);
            border: none;
            cursor: pointer;
            color: var(--ink-tertiary);
            width: 28px;
            height: 28px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: color 0.15s, background 0.15s;
            font-size: 16px;
        }
        .slide-panel-close:hover { background: var(--line); color: var(--ink); }
        .slide-panel-body {
            flex: 1;
            overflow-y: auto;
            padding: 0 18px max(20px, env(safe-area-inset-bottom, 20px));
            -webkit-overflow-scrolling: touch;
        }
        .slide-panel-body::-webkit-scrollbar { width: 0; }
        .panel-section { margin-bottom: 20px; }
        .panel-section-label {
            font-size: 10px;
            font-weight: 600;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--ink-faint);
            margin-bottom: 10px;
            padding-top: 6px;
        }
        .slide-panel-tab-nav {
            display: flex;
            gap: 0;
            border-bottom: 1px solid var(--line);
            padding: 0 18px;
            margin-bottom: 12px;
        }
        .slide-panel-tab-nav button {
            font-family: var(--font-body);
            font-size: 11px;
            font-weight: 500;
            color: var(--ink-tertiary);
            background: none;
            border: none;
            padding: 8px 10px 6px;
            cursor: pointer;
            border-bottom: 2px solid transparent;
        }
        .slide-panel-tab-nav button.active {
            color: var(--coach);
            border-bottom-color: var(--coach);
        }

        /* ── SUGGESTION CHIPS ── */
        .chips-row {
            display: flex;
            gap: 6px;
            flex-wrap: wrap;
            margin: 8px 0 12px;
        }
        .chip {
            font-family: var(--font-body);
            font-size: 12px;
            padding: 7px 14px;
            background: var(--coach-light);
            color: var(--coach);
            border: none;
            border-radius: 20px;
            cursor: pointer;
            transition: all 0.15s;
            white-space: nowrap;
        }
        .chip:hover { background: var(--coach); color: white; }

        /* ── RESPONSIVE BREAKPOINTS ── */
        @media (max-width: 400px) {
            .conversation { padding: 16px 12px 8px; }
            .input-area { padding: 8px 12px max(12px, env(safe-area-inset-bottom, 12px)); }
            .top-bar { padding: 12px 14px; }
            .top-bar-title { font-size: 16px; }
            .param-card { max-width: 100%; }
            .cmd-palette { left: 0; right: 0; }
        }
        @media (min-width: 401px) and (max-width: 600px) {
            .conversation { padding: 18px 14px 8px; }
            .param-card { max-width: 100%; }
            .cmd-palette { left: 0; right: 0; }
        }
        @media (min-width: 601px) and (max-width: 840px) {
            .conversation { padding: 24px 20px 8px; }
            .conversation-inner { max-width: 580px; }
        }
        @media (min-width: 841px) {
            .conversation { padding: 28px 24px 8px; }
            .conversation-inner { max-width: 640px; }
            .input-inner { max-width: 640px; }
        }

        /* ── MSG TIMESTAMP ── */
        .msg-time {
            text-align: center;
            font-size: 11px;
            color: var(--ink-faint);
            margin: 16px 0 10px;
        }
"""

# Insert new CSS before the closing </style> tag
content = content.replace('    </style>', new_css + '    </style>')

# ============================================================
# 3. REPLACE HTML STRUCTURE:
#    - Keep auth screen but update styling
#    - Keep FTUE wizard
#    - Replace app container with conversation-first layout
#    - Keep all overlays
# ============================================================

# Replace the auth screen with updated design
old_auth = """    <!-- ═══ AUTH SCREEN ═══ -->
    <div class="auth-screen" id="authScreen">
        <div class="auth-card">
            <div class="auth-title">coach alfred</div>
            <p class="auth-subtitle">sharpen your genius</p>
            <input type="password" id="passcodeInput" class="auth-input" placeholder="Passcode" onkeydown="if(event.key==='Enter') authenticate()">
            <button class="auth-button" onclick="authenticate()">Sign In</button>
            <div id="authError" class="auth-error hidden"></div>
            <div id="authVersion" class="auth-version">v2.0.6</div>
        </div>
    </div>"""

new_auth = """    <!-- ═══ AUTH SCREEN ═══ -->
    <div class="auth-screen" id="authScreen" style="position:fixed;inset:0;z-index:1000;">
        <div class="auth-card">
            <div class="auth-title">coach alfred</div>
            <p class="auth-subtitle">sharpen your genius</p>
            <input type="password" id="passcodeInput" class="auth-input" placeholder="passcode" onkeydown="if(event.key==='Enter') authenticate()" style="letter-spacing:6px;">
            <button class="auth-button" onclick="authenticate()">Sign In</button>
            <div id="authError" class="auth-error hidden"></div>
            <div id="authVersion" class="auth-version">v2.0.6</div>
        </div>
    </div>"""

content = content.replace(old_auth, new_auth)

# Replace the entire app container (from <!-- ═══ APP CONTAINER ═══ --> to the closing </div> before tool overlay)
old_app_start = """    <!-- ═══ APP CONTAINER ═══ -->
    <div id="appContainer" class="hidden" style="display:flex;flex-direction:column;height:100dvh;">

        <!-- Screen Nav -->
        <nav class="screen-nav" id="screenNav">
            <button class="active" onclick="showScreen('day')">today</button>
            <button onclick="showScreen('coaching')">coaching</button>
            <button onclick="showScreen('settings')">settings</button>
        </nav>

        <!-- ═══ SCREEN: TODAY ═══ -->
        <div class="screen active" id="screen-day">
            <div class="header">
                <div class="header-title">coach alfred</div>
                <div class="header-meta">
                    <span id="greetingTime">loading...</span>
                    <span class="header-icon" onclick="showScreen('settings')" title="Settings">&#9881;</span>
                </div>
            </div>
            <div class="pulse" id="pulseText">scanning...</div>
            <div class="canvas" id="canvas-day">
                <!-- Health warning -->
                <div id="healthWarningBanner" class="card evidence-card hidden" style="margin-bottom:12px;">
                    <div class="card-header">&#9888; System Health</div>
                    <div id="healthWarningList" style="font-size:12px;"></div>
                </div>
                <!-- Morning Walk Thread (conversation-first) -->
                <div id="morningWalkThread"></div>
                <!-- Weekly review (Sundays) -->
                <div id="weeklyReviewSection" class="hidden"></div>
                <!-- Chat messages render here dynamically -->
            </div>
        </div>"""

# Find the end of settings screen and bottom bar
old_app_end_marker = """        <!-- Bottom Bar -->
        <div class="bottom-bar" id="bottomBar">
            <div class="pills">
                <button class="pill pill-primary" onclick="focusChatInput()">Talk to Alfred</button>
                <button class="pill" onclick="showCapabilityCard('calendar')">Calendar</button>
                <button class="pill" onclick="showCapabilityCard('commitments')">Commitments</button>
                <button class="pill" onclick="showCapabilityCard('messages')">Messages</button>
                <button class="pill" onclick="sendChat('What\\'s the highest leverage thing I can do right now?')">Focus</button>
                <button class="pill" onclick="sendChat('Draft a follow-up nudge')">Nudge</button>
            </div>
            <div class="input-row">
                <textarea class="input-field" id="chatInput" placeholder="Talk to Alfred..." rows="1" oninput="autoResizeTextarea(this)" onkeydown="handleChatKeydown(event)"></textarea>
                <button class="send-btn" id="sendBtn" onclick="sendChat()">&#x2191;</button>
            </div>
        </div>
    </div>"""

# We need to find and replace from app container start through bottom bar end
# Find the coaching and settings screens between
app_container_match = content.find('    <!-- ═══ APP CONTAINER ═══ -->')
bottom_bar_end = content.find('    </div>\n\n    <!-- ═══ TOOL OVERLAY ═══ -->')

if app_container_match > 0 and bottom_bar_end > 0:
    old_app_section = content[app_container_match:bottom_bar_end]

    new_app_section = """    <!-- ═══ APP CONTAINER ═══ -->
    <div id="appContainer" class="hidden" style="display:flex;flex-direction:column;height:100dvh;">

        <!-- TOP BAR -->
        <div class="top-bar">
            <div class="top-bar-title">coach alfred</div>
            <div class="top-bar-actions">
                <span id="greetingTime" style="font-size:11px;color:var(--ink-faint);margin-right:4px;">loading...</span>
                <button class="top-bar-btn" id="themeToggleBtn" onclick="toggleTheme()" title="Toggle dark mode">&#9728;&#65039;</button>
                <button class="top-bar-btn" onclick="openSettingsPanel()" title="Settings">&#9881;&#65039;</button>
            </div>
        </div>

        <!-- CONVERSATION -->
        <div class="conversation" id="conversationScroll">
            <div class="conversation-inner" id="conversation">
                <!-- Health warning -->
                <div id="healthWarningBanner" class="card evidence-card hidden" style="margin-bottom:12px;">
                    <div class="card-header">&#9888; System Health</div>
                    <div id="healthWarningList" style="font-size:12px;"></div>
                </div>
                <!-- Morning Walk Thread -->
                <div id="morningWalkThread"></div>
                <!-- Weekly review (Sundays) -->
                <div id="weeklyReviewSection" class="hidden"></div>
                <!-- Chat messages render here dynamically -->
            </div>
        </div>

        <!-- PULSE SUBTITLE (hidden, used for data) -->
        <div id="pulseText" class="hidden">scanning...</div>

        <!-- INPUT AREA -->
        <div class="input-area" id="inputArea">
            <div class="input-inner" id="inputInner">
                <!-- Slash palette renders here dynamically -->
                <div class="input-row-v2">
                    <textarea id="chatInput" rows="1" placeholder="Talk to Alfred..." oninput="handleInput(event)" onkeydown="handleKeydown(event)"></textarea>
                    <button class="send-btn-v2" id="sendBtn" onclick="sendChat()">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="19" x2="12" y2="5"/><polyline points="5 12 12 5 19 12"/></svg>
                    </button>
                </div>
                <div class="input-hint">Type / for tools</div>
            </div>
        </div>
    </div>

    <!-- ═══ SETTINGS PANEL (Slide-up) ═══ -->
    <div class="panel-overlay" id="panelOverlay" onclick="closeSettingsPanel()"></div>
    <div class="slide-panel" id="settingsPanel">
        <div class="slide-panel-inner">
            <div class="slide-panel-handle" onclick="closeSettingsPanel()"></div>
            <div class="slide-panel-header">
                <div class="slide-panel-title">Settings</div>
                <div style="display:flex;align-items:center;gap:8px;">
                    <span id="appVersion" style="font-size:11px;color:var(--ink-faint);">v2.0.6</span>
                    <button style="font-family:var(--font-body);font-size:12px;color:var(--danger);background:none;border:none;cursor:pointer;font-weight:500;" onclick="logout()">Logout</button>
                    <button class="slide-panel-close" onclick="closeSettingsPanel()">&times;</button>
                </div>
            </div>
            <div class="slide-panel-tab-nav" id="settingsPanelTabs">
                <button class="active" onclick="showSettingsTab('tenets',this)">tenets</button>
                <button onclick="showSettingsTab('skills',this)">skills</button>
                <button onclick="showSettingsTab('config',this)">config</button>
                <button onclick="showSettingsTab('previews',this)">previews</button>
                <button onclick="showSettingsTab('library',this)">library</button>
            </div>
            <div class="slide-panel-body">
                <!-- TENETS TAB -->
                <div id="panelTabTenets">
                    <div class="panel-section">
                        <div class="panel-section-label">COACHING TENETS</div>
                        <div id="tenetSectionsList"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px 0;">Loading...</div></div>
                    </div>
                </div>
                <!-- SKILLS TAB -->
                <div id="panelTabSkills" style="display:none;">
                    <div class="panel-section">
                        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;">
                            <div class="panel-section-label" style="margin:0;padding:0;">YOUR SKILLS</div>
                            <button class="btn btn-sm" onclick="openSkillEditor()">+ New</button>
                        </div>
                        <div class="config-card" id="userSkillsList"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px 0;">Loading...</div></div>
                        <div class="panel-section-label">INSTALLED SKILLS</div>
                        <div class="config-card" id="installedSkillsList"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px 0;">Loading...</div></div>
                    </div>
                </div>
                <!-- CONFIG TAB -->
                <div id="panelTabConfig" style="display:none;">
                    <!-- Cadences -->
                    <div class="panel-section">
                        <div class="panel-section-label">CADENCES</div>
                        <div class="config-card" id="cadenceStatusContent"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px 0;">Loading...</div></div>
                    </div>
                    <!-- Favorites -->
                    <div class="panel-section">
                        <div class="panel-section-label">FAVORITES</div>
                        <div class="config-card">
                            <div id="favoriteContactsList"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px;">Loading...</div></div>
                            <div style="padding:12px 16px;border-top:1px solid var(--line);">
                                <div style="font-size:11px;font-weight:600;color:var(--ink-tertiary);margin-bottom:6px;">ADD CONTACT</div>
                                <input type="text" id="newContactName" placeholder="Name" class="form-input" style="margin-bottom:6px;">
                                <input type="text" id="newContactAliases" placeholder="Aliases (comma separated)" class="form-input" style="margin-bottom:6px;">
                                <div style="display:flex;gap:12px;align-items:center;font-size:12px;margin-bottom:8px;">
                                    <label><input type="checkbox" id="contactWhatsapp" checked> WhatsApp</label>
                                    <label><input type="checkbox" id="contactIMessage" checked> iMessage</label>
                                    <label><input type="checkbox" id="contactEmail"> Email</label>
                                </div>
                                <button class="btn btn-sm btn-coach" onclick="addFavoriteContact()">Add</button>
                                <div id="addContactStatus" class="hidden" style="margin-top:4px;"></div>
                            </div>
                        </div>
                        <div class="config-card">
                            <div id="favoriteGroupsList"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px;">No groups yet</div></div>
                            <div style="padding:12px 16px;border-top:1px solid var(--line);">
                                <div style="font-size:11px;font-weight:600;color:var(--ink-tertiary);margin-bottom:6px;">ADD GROUP</div>
                                <input type="text" id="newGroupName" placeholder="Group name" class="form-input" style="margin-bottom:6px;">
                                <input type="text" id="newGroupAliases" placeholder="Aliases" class="form-input" style="margin-bottom:6px;">
                                <select id="groupPlatform" class="form-input" style="margin-bottom:8px;">
                                    <option value="whatsapp">WhatsApp</option>
                                    <option value="imessage">iMessage</option>
                                </select>
                                <button class="btn btn-sm btn-coach" onclick="addFavoriteGroup()">Add</button>
                                <div id="addGroupStatus" class="hidden" style="margin-top:4px;"></div>
                            </div>
                        </div>
                    </div>
                    <!-- Notion Config -->
                    <div class="panel-section">
                        <div class="panel-section-label">NOTION</div>
                        <div class="config-card">
                            <div class="config-row">
                                <div><span>Tasks Database</span><div id="tasksDbNameLabel" style="font-size:11px;color:var(--ink-tertiary);display:none;"></div></div>
                                <span class="config-value" id="currentTasksDatabaseId"></span>
                            </div>
                            <div style="padding:12px 16px;border-top:1px solid var(--line);">
                                <input type="text" id="tasksDatabaseId" placeholder="Database ID or URL" class="form-input" style="margin-bottom:6px;">
                                <div style="font-size:11px;color:var(--ink-tertiary);margin-bottom:8px;">Context databases:</div>
                                <input type="text" id="contextDb1" placeholder="Context DB 1" class="form-input" style="margin-bottom:4px;font-size:12px;">
                                <span id="contextDb1Status" style="font-size:10px;color:var(--ink-tertiary);"></span>
                                <input type="text" id="contextDb2" placeholder="Context DB 2" class="form-input" style="margin-bottom:4px;font-size:12px;">
                                <span id="contextDb2Status" style="font-size:10px;color:var(--ink-tertiary);"></span>
                                <input type="text" id="contextDb3" placeholder="Context DB 3" class="form-input" style="margin-bottom:4px;font-size:12px;">
                                <span id="contextDb3Status" style="font-size:10px;color:var(--ink-tertiary);"></span>
                                <input type="text" id="contextDb4" placeholder="Context DB 4" class="form-input" style="margin-bottom:6px;font-size:12px;">
                                <span id="contextDb4Status" style="font-size:10px;color:var(--ink-tertiary);"></span>
                                <button class="btn btn-sm btn-coach" onclick="saveNotionConfig()" style="margin-top:4px;">Save</button>
                                <div id="notionConfigStatus" class="hidden" style="margin-top:4px;"></div>
                            </div>
                        </div>
                    </div>
                    <!-- Appearance -->
                    <div class="panel-section">
                        <div class="panel-section-label">APPEARANCE</div>
                        <div class="config-card">
                            <div class="config-row">
                                <span>Dark Mode</span>
                                <div class="toggle" id="themeToggle" onclick="toggleTheme()"></div>
                            </div>
                        </div>
                    </div>
                    <!-- Security -->
                    <div class="panel-section">
                        <div class="panel-section-label">SECURITY</div>
                        <div class="config-card">
                            <div style="padding:12px 16px;">
                                <div style="font-size:11px;font-weight:600;color:var(--ink-tertiary);margin-bottom:8px;">CHANGE PASSCODE</div>
                                <input type="password" id="currentPasscode" placeholder="Current passcode" class="form-input" style="margin-bottom:6px;">
                                <input type="password" id="newPasscode" placeholder="New passcode" class="form-input" style="margin-bottom:6px;">
                                <input type="password" id="confirmPasscode" placeholder="Confirm new passcode" class="form-input" style="margin-bottom:8px;">
                                <button class="btn btn-sm" onclick="changePasscode()">Update Passcode</button>
                                <div id="passcodeStatus" class="hidden" style="margin-top:4px;"></div>
                            </div>
                        </div>
                    </div>
                    <!-- Data -->
                    <div class="panel-section">
                        <div class="panel-section-label">DATA</div>
                        <div class="config-card">
                            <div class="config-row">
                                <span>Clear Server Cache</span>
                                <button class="btn btn-sm" onclick="clearCache()">Clear</button>
                            </div>
                            <div id="cacheStatus" class="hidden" style="padding:0 16px 8px;"></div>
                            <div class="config-row">
                                <span>Patterns & Memory</span>
                                <button class="btn btn-sm" onclick="showPatternsAndMemory()">View</button>
                            </div>
                        </div>
                    </div>
                </div>
                <!-- PREVIEWS TAB -->
                <div id="panelTabPreviews" style="display:none;">
                    <div class="panel-section">
                        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">
                            <div class="panel-section-label" style="margin:0;padding:0;">CARD PREVIEWS</div>
                            <div style="display:flex;gap:8px;align-items:center;">
                                <span id="qaDebugMeta" style="font-size:11px;color:var(--ink-faint);"></span>
                                <button class="btn btn-sm" onclick="refreshAllQA()">Refresh All</button>
                            </div>
                        </div>
                        <div id="qaCardsList"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px 0;">Loading...</div></div>
                    </div>
                </div>
                <!-- LIBRARY TAB -->
                <div id="panelTabLibrary" style="display:none;">
                    <div class="panel-section">
                        <div class="panel-section-label">SKILL LIBRARY</div>
                        <div class="config-card" id="libraryList"><div style="font-size:12px;color:var(--ink-tertiary);padding:8px 0;">Loading...</div></div>
                    </div>
                </div>
            </div>
        </div>
    </div>
"""

    content = content[:app_container_match] + new_app_section + content[bottom_bar_end:]


# ============================================================
# 4. REPLACE/ADAPT JAVASCRIPT
# ============================================================

# 4a. Replace showScreen/showCoachingTab with settings panel functions + slash command system
old_nav_js = """        let currentScreen = 'day';

        function showScreen(id) {
            currentScreen = id;
            document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
            document.getElementById('screen-' + id).classList.add('active');

            // Update nav buttons
            document.querySelectorAll('#screenNav button').forEach(btn => {
                btn.classList.toggle('active', btn.textContent.trim() === (id === 'day' ? 'today' : id));
            });

            // Show/hide bottom bar (only on today screen)
            const bar = document.getElementById('bottomBar');
            bar.style.display = id === 'day' ? '' : 'none';

            // Lazy-load screen data
            if (id === 'coaching') {
                loadTenets();
                loadSkillsList();
            } else if (id === 'settings') {
                loadCadenceStatus();
                loadFavorites();
                loadSettings();
            }
        }

        function showCoachingTab(tab, btn) {
            ['tenets', 'skills', 'previews', 'library'].forEach(t => {
                const el = document.getElementById('coachingTab' + t.charAt(0).toUpperCase() + t.slice(1));
                if (el) el.style.display = t === tab ? '' : 'none';
            });
            document.querySelectorAll('#coachingTabNav button').forEach(b => b.classList.remove('active'));
            if (btn) btn.classList.add('active');

            if (tab === 'previews') loadQAPreview();
            if (tab === 'library') loadLibrary();
        }"""

new_nav_js = """        let currentScreen = 'day';

        // Conversation-first: no screen tabs, single view
        function showScreen(id) {
            currentScreen = id;
            // In conversation-first mode, settings opens the slide panel
            if (id === 'settings') openSettingsPanel();
            if (id === 'coaching') { openSettingsPanel(); showSettingsTab('tenets'); }
        }

        // Settings panel management
        function openSettingsPanel() {
            document.getElementById('panelOverlay').classList.add('open');
            document.getElementById('settingsPanel').classList.add('open');
            // Load data for active tab
            loadTenets();
            loadSkillsList();
            loadCadenceStatus();
            loadFavorites();
            loadSettings();
        }

        function closeSettingsPanel() {
            document.getElementById('panelOverlay').classList.remove('open');
            document.getElementById('settingsPanel').classList.remove('open');
        }

        function showSettingsTab(tab, btn) {
            const tabs = ['tenets', 'skills', 'config', 'previews', 'library'];
            tabs.forEach(t => {
                const el = document.getElementById('panelTab' + t.charAt(0).toUpperCase() + t.slice(1));
                if (el) el.style.display = t === tab ? '' : 'none';
            });
            document.querySelectorAll('#settingsPanelTabs button').forEach(b => b.classList.remove('active'));
            if (btn) btn.classList.add('active');
            else {
                const buttons = document.querySelectorAll('#settingsPanelTabs button');
                buttons.forEach(b => { if (b.textContent.trim() === tab) b.classList.add('active'); });
            }
            if (tab === 'previews') loadQAPreview();
            if (tab === 'library') loadLibrary();
        }

        // Slash command system
        let paletteOpen = false;
        let paletteIdx = 0;
        let filteredCmds = [];

        const COMMANDS = [
            { icon: '\\u{1F4C5}', name: '/calendar',    desc: "Today's schedule",   hasParams: true },
            { icon: '\\u2713',    name: '/commitments', desc: 'Track commitments',  hasParams: true },
            { icon: '\\u{1F4AC}', name: '/messages',    desc: 'Message summaries',  hasParams: true },
            { icon: '\\u{1F3AF}', name: '/focus',       desc: 'Top priority',       hasParams: false },
            { icon: '\\u{1F4DD}', name: '/nudge',       desc: 'Draft follow-up',    hasParams: false },
            { icon: '\\u{1F4CA}', name: '/briefing',    desc: 'Daily briefing',     hasParams: false },
            { icon: '\\u2699\\uFE0F', name: '/settings',    desc: 'Coaching config',    hasParams: false },
            { icon: '\\u{1F4DA}', name: '/skills',      desc: 'Skill library',      hasParams: false },
        ];

        function showPalette(filter) {
            const q = (filter || '').toLowerCase().replace(/^\\//, '');
            filteredCmds = q ? COMMANDS.filter(c => c.name.toLowerCase().includes(q) || c.desc.toLowerCase().includes(q)) : COMMANDS;
            paletteIdx = 0;
            const container = document.getElementById('inputInner');
            let palette = document.getElementById('cmdPalette');
            if (!palette) {
                palette = document.createElement('div');
                palette.id = 'cmdPalette';
                palette.className = 'cmd-palette';
                container.insertBefore(palette, container.firstChild);
            }
            if (filteredCmds.length === 0) {
                palette.innerHTML = '<div class="cmd-no-results">No matching commands</div>';
            } else {
                let html = '<div class="cmd-palette-header"><span>Commands</span><button class="cmd-palette-close" onclick="closePalette()">&times;</button></div>';
                filteredCmds.forEach((cmd, i) => {
                    html += '<div class="cmd-item' + (i === 0 ? ' active' : '') + '" data-idx="' + i + '" onclick="selectCommand(' + i + ')" onmouseenter="highlightCmd(' + i + ')">'
                        + '<span class="cmd-icon">' + cmd.icon + '</span>'
                        + '<span class="cmd-name">' + cmd.name + '</span>'
                        + '<span class="cmd-desc">' + cmd.desc + '</span>'
                        + '</div>';
                });
                palette.innerHTML = html;
            }
            palette.style.display = '';
            paletteOpen = true;
        }

        function closePalette() {
            const palette = document.getElementById('cmdPalette');
            if (palette) palette.style.display = 'none';
            paletteOpen = false;
        }

        function highlightCmd(idx) {
            paletteIdx = idx;
            document.querySelectorAll('#cmdPalette .cmd-item').forEach((el, i) => {
                el.classList.toggle('active', i === idx);
            });
        }

        function selectCommand(idx) {
            const cmd = filteredCmds[idx];
            if (!cmd) return;
            const input = document.getElementById('chatInput');
            input.value = '';
            closePalette();

            if (cmd.name === '/settings') { openSettingsPanel(); return; }
            if (cmd.name === '/skills') { openSettingsPanel(); showSettingsTab('library'); return; }
            if (cmd.hasParams) {
                showParamForm(cmd.name);
            } else {
                const queries = {
                    '/focus': "What's the highest leverage thing I can do right now?",
                    '/nudge': 'Draft a follow-up nudge',
                    '/briefing': 'Give me my daily briefing'
                };
                sendChat(queries[cmd.name] || cmd.name);
            }
        }

        function showParamForm(cmdName) {
            const conv = document.getElementById('conversation');
            const inner = conv.querySelector('.conversation-inner') || conv;
            const cardId = 'param-' + Date.now();
            const div = document.createElement('div');
            div.id = cardId;

            const configs = {
                '/calendar': {
                    title: 'Calendar',
                    groups: [
                        { label: 'Date', key: 'date', options: ['Today', 'Tomorrow', 'This Week'], defaultVal: 'Today' },
                        { label: 'Show', key: 'filter', options: ['All', 'Work', 'Personal'], defaultVal: 'All' }
                    ],
                    buildQuery: function(s) {
                        const filter = s.filter === 'All' ? '' : s.filter.toLowerCase() + ' ';
                        const date = s.date === 'Today' ? 'today' : s.date === 'Tomorrow' ? 'tomorrow' : 'this week';
                        return "What's on my " + filter + "calendar " + date + "?";
                    }
                },
                '/commitments': {
                    title: 'Commitments',
                    groups: [
                        { label: 'Show', key: 'scope', options: ['All', 'Overdue', 'I Owe', 'They Owe'], defaultVal: 'All' }
                    ],
                    contactInput: true,
                    contactPlaceholder: 'e.g. Mona, Vasanth',
                    buildQuery: function(s) {
                        var person = s.contact ? ' with ' + s.contact : '';
                        if (s.scope === 'All' && s.contact) return 'Show me commitments with ' + s.contact;
                        if (s.scope === 'All') return 'How are my commitments looking?';
                        if (s.scope === 'Overdue') return 'Show me overdue commitments' + person;
                        if (s.scope === 'I Owe') return 'Show me commitments I owe' + person;
                        return 'Show me commitments others owe me' + (s.contact ? ' from ' + s.contact : '');
                    }
                },
                '/messages': {
                    title: 'Messages',
                    groups: [
                        { label: 'Platform', key: 'platform', options: ['All', 'WhatsApp', 'iMessage', 'Signal'], defaultVal: 'All' },
                        { label: 'Period', key: 'period', options: ['Today', '3 Days', 'This Week'], defaultVal: 'Today' }
                    ],
                    contactInput: true,
                    buildQuery: function(s) {
                        const platform = s.platform === 'All' ? '' : s.platform + ' ';
                        const period = s.period === 'Today' ? 'from today' : s.period === '3 Days' ? 'from the last 3 days' : 'from this week';
                        const contact = s.contact ? ' from ' + s.contact : '';
                        return 'Summarize my ' + platform + 'messages' + contact + ' ' + period;
                    }
                }
            };

            const cfg = configs[cmdName];
            if (!cfg) return;

            let html = '<div class="param-card"><h3>' + cfg.title + '</h3>';
            if (cfg.contactInput) {
                html += '<div class="param-label">' + (cfg.contactLabel || 'Contact') + '</div>';
                html += '<input type="text" class="param-input" placeholder="' + (cfg.contactPlaceholder || 'optional') + '" data-key="contact">';
            }
            cfg.groups.forEach(g => {
                html += '<div class="param-label">' + g.label + '</div><div class="param-toggles">';
                g.options.forEach(opt => {
                    html += '<button class="param-toggle' + (opt === g.defaultVal ? ' active' : '') + '" data-key="' + g.key + '" data-value="' + opt + '" onclick="toggleParam(this)">' + opt + '</button>';
                });
                html += '</div>';
            });
            html += '<button class="param-go-btn" onclick="fireParamCommand(\\'' + cardId + '\\')">Go \\u2192</button></div>';
            div.innerHTML = html;
            div._paramConfig = cfg;
            inner.appendChild(div);
            div.scrollIntoView({ behavior: 'smooth', block: 'end' });
        }

        function toggleParam(el) {
            const key = el.dataset.key;
            el.parentElement.querySelectorAll('[data-key="' + key + '"]').forEach(b => b.classList.remove('active'));
            el.classList.add('active');
        }

        function fireParamCommand(cardId) {
            const card = document.getElementById(cardId);
            if (!card || !card._paramConfig) return;
            const selections = {};
            card.querySelectorAll('.param-toggle.active').forEach(b => { selections[b.dataset.key] = b.dataset.value; });
            const contactInput = card.querySelector('.param-input');
            if (contactInput && contactInput.value.trim()) selections.contact = contactInput.value.trim();
            const query = card._paramConfig.buildQuery(selections);
            card.style.opacity = '0.4';
            card.style.pointerEvents = 'none';
            sendChat(query);
        }

        // Input handling with slash palette
        function handleInput(event) {
            const input = event.target;
            const val = input.value;
            // Auto-resize
            input.style.height = 'auto';
            input.style.height = Math.min(input.scrollHeight, 96) + 'px';
            // Slash palette
            if (val.startsWith('/')) {
                showPalette(val);
            } else {
                closePalette();
            }
        }

        function handleKeydown(event) {
            if (paletteOpen) {
                if (event.key === 'ArrowDown') {
                    event.preventDefault();
                    paletteIdx = Math.min(paletteIdx + 1, filteredCmds.length - 1);
                    highlightCmd(paletteIdx);
                } else if (event.key === 'ArrowUp') {
                    event.preventDefault();
                    paletteIdx = Math.max(paletteIdx - 1, 0);
                    highlightCmd(paletteIdx);
                } else if (event.key === 'Enter') {
                    event.preventDefault();
                    selectCommand(paletteIdx);
                } else if (event.key === 'Escape') {
                    closePalette();
                    document.getElementById('chatInput').value = '';
                }
            } else {
                if (event.key === 'Enter' && !event.shiftKey) {
                    event.preventDefault();
                    sendChat();
                }
            }
        }"""

content = content.replace(old_nav_js, new_nav_js)

# 4b. Update handleChatKeydown and sendChat to work with new input
old_chat_keydown = """        function handleChatKeydown(event) {
            if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); sendChat(); }
        }

        function sendChat(prefilled) {
            const input = document.getElementById('chatInput');
            const text = prefilled || input.value.trim();
            if (!text) return;
            if (currentScreen !== 'day') showScreen('day');
            if (!prefilled) { input.value = ''; autoResizeTextarea(input); }
            sendChatMessage(text);
        }"""

new_chat_fn = """        function sendChat(prefilled) {
            const input = document.getElementById('chatInput');
            const text = prefilled || input.value.trim();
            if (!text) return;
            closePalette();
            if (!prefilled) { input.value = ''; input.style.height = 'auto'; }
            sendChatMessage(text);
        }"""

content = content.replace(old_chat_keydown, new_chat_fn)

# 4c. Update showCapabilityCard to render into conversation-inner
old_show_cap = """        function showCapabilityCard(type) {
            if (currentScreen !== 'day') showScreen('day');
            const canvas = document.getElementById('canvas-day');"""

new_show_cap = """        function showCapabilityCard(type) {
            const conv = document.getElementById('conversationScroll');
            const canvas = conv ? (conv.querySelector('.conversation-inner') || conv) : document.getElementById('conversation');"""

content = content.replace(old_show_cap, new_show_cap)

# 4d. Update addChatBubble/createStreamingBubble targets
old_add_chat = """        function addChatBubble(sender, content) {
            const canvas = document.getElementById('canvas-day');"""

new_add_chat = """        function addChatBubble(sender, content) {
            const conv = document.getElementById('conversationScroll');
            const canvas = conv ? (conv.querySelector('.conversation-inner') || conv) : document.getElementById('conversation');"""

content = content.replace(old_add_chat, new_add_chat)

old_create_stream = """        function createStreamingBubble() {
            const canvas = document.getElementById('canvas-day');"""

new_create_stream = """        function createStreamingBubble() {
            const conv = document.getElementById('conversationScroll');
            const canvas = conv ? (conv.querySelector('.conversation-inner') || conv) : document.getElementById('conversation');"""

content = content.replace(old_create_stream, new_create_stream)

# 4e. Update renderMorningWalk target
content = content.replace(
    "const thread = document.getElementById('morningWalkThread');\n            if (!thread) return;",
    "const thread = document.getElementById('morningWalkThread');\n            if (!thread) return;"
)

# 4f. Update showApp to remove tab references
old_show_app = """        function showApp() {
            if (_appLoaded) return;
            _appLoaded = true;
            document.getElementById('authScreen').classList.add('hidden');
            document.getElementById('appContainer').classList.remove('hidden');
            document.getElementById('ftueWizard').classList.add('hidden');

            initTheme();
            startGreetingClock();
            loadMorningWalk();
            if (isSunday()) loadWeeklyReflection();
        }"""

new_show_app = """        function showApp() {
            if (_appLoaded) return;
            _appLoaded = true;
            document.getElementById('authScreen').classList.add('hidden');
            document.getElementById('appContainer').classList.remove('hidden');
            document.getElementById('appContainer').style.display = 'flex';
            document.getElementById('ftueWizard').classList.add('hidden');

            initTheme();
            startGreetingClock();
            loadMorningWalk();
            if (isSunday()) loadWeeklyReflection();
        }"""

content = content.replace(old_show_app, new_show_app)

# 4g. Update theme management to work with new toggle button
old_apply_theme = """        function applyTheme(theme) {
            if (theme === 'dark') {
                document.documentElement.setAttribute('data-theme', 'dark');
                const toggle = document.getElementById('themeToggle');
                if (toggle) toggle.classList.add('on');
            } else {
                document.documentElement.removeAttribute('data-theme');
                const toggle = document.getElementById('themeToggle');
                if (toggle) toggle.classList.remove('on');
            }
            localStorage.setItem('alfred-theme', theme);
        }"""

new_apply_theme = """        function applyTheme(theme) {
            if (theme === 'dark') {
                document.documentElement.setAttribute('data-theme', 'dark');
                const toggle = document.getElementById('themeToggle');
                if (toggle) toggle.classList.add('on');
                const btn = document.getElementById('themeToggleBtn');
                if (btn) btn.textContent = '\\u{1F319}';
            } else {
                document.documentElement.removeAttribute('data-theme');
                const toggle = document.getElementById('themeToggle');
                if (toggle) toggle.classList.remove('on');
                const btn = document.getElementById('themeToggleBtn');
                if (btn) btn.textContent = '\\u2600\\uFE0F';
            }
            localStorage.setItem('alfred-theme', theme);
        }"""

content = content.replace(old_apply_theme, new_apply_theme)

# 4h. Update focusChatInput
old_focus = """        function focusChatInput() {
            const input = document.getElementById('chatInput');
            if (input) {
                input.focus();
                input.placeholder = 'Ask anything \\u2014 calendar, commitments, messages, coaching...';
            }
        }"""

new_focus = """        function focusChatInput() {
            const input = document.getElementById('chatInput');
            if (input) {
                input.focus();
                input.placeholder = 'Ask anything — calendar, commitments, messages, coaching...';
            }
        }"""

content = content.replace(old_focus, new_focus)

# 4i. Update refreshing indicator to use conversation container
content = content.replace(
    "const thread = document.getElementById('morningWalkThread');\n            if (!thread) return;\n            const indicator = document.createElement('div');",
    "const thread = document.getElementById('morningWalkThread');\n            if (!thread) return;\n            const indicator = document.createElement('div');"
)

# 4j. Add suggestion chips after morning walk
old_accountability = """            // 7. Accountability question
            html += '<div class="coach-question">' + escapeHtml(buildAccountabilityQuestion(pulseData)) + '</div>';

            thread.innerHTML = html;"""

new_accountability = """            // 7. Accountability question
            html += '<div class="coach-question">' + escapeHtml(buildAccountabilityQuestion(pulseData)) + '</div>';

            // 8. Suggestion chips
            html += '<div class="chips-row">'
                + '<button class="chip" onclick="sendChat(\\'What\\\\'s on my calendar today?\\')">Calendar</button>'
                + '<button class="chip" onclick="sendChat(\\'How are my commitments looking?\\')">Commitments</button>'
                + '<button class="chip" onclick="sendChat(\\'Draft a follow-up nudge\\')">Nudge</button>'
                + '<button class="chip" onclick="sendChat(\\'What should I focus on?\\')">Focus</button>'
                + '</div>';

            thread.innerHTML = html;"""

content = content.replace(old_accountability, new_accountability)

# 4k. Fix the scrollIntoView to scroll the conversation container
content = content.replace(
    "div.scrollIntoView({ behavior: 'smooth', block: 'end' });",
    "div.scrollIntoView({ behavior: 'smooth', block: 'end' });"
)

# ============================================================
# 5. Write the output
# ============================================================

# Write to hot-reload location
with open(HOME_HTML, 'w') as f:
    f.write(content)

# Write to source repo
with open(SOURCE_HTML, 'w') as f:
    f.write(content)

print(f"Done! Wrote {len(content)} chars ({content.count(chr(10))} lines) to both locations.")
