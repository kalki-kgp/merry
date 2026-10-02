import Foundation

/* ------------------------------------------------------------------ *
 * Scripts. Kept as named constants so they can be read and reviewed in
 * one place; each returns plain JSON.
 *
 * Each is JavaScript source run by osascript, held in a raw string whose
 * closing delimiter sits at the left margin so no indentation is stripped.
 * ------------------------------------------------------------------ */

public enum SCRIPTS {
    public static let calendars = #"""

    const Cal = Application('Calendar')
    const cals = Cal.calendars
    const names = cals.name(), writable = cals.writable()
    return names.map((name, i) => ({ name, writable: writable[i] }))
"""#

    public static let events = #"""

    const Cal = Application('Calendar')
    const from = new Date(input.from), to = new Date(input.to), out = []
    for (const c of Cal.calendars()) {
      const name = c.name()
      if (input.calendars && input.calendars.length && !input.calendars.includes(name)) continue
      // One Apple event per property for the whole set, not one per event.
      const q = c.events.whose({ _and: [{ startDate: { _lessThan: to } }, { endDate: { _greaterThan: from } }] })
      const ids = q.uid()
      if (!ids.length) continue
      const titles = q.summary(), starts = q.startDate(), ends = q.endDate(), allDay = q.alldayEvent(), where = q.location()
      ids.forEach((id, i) => out.push({ id, title: titles[i], start: starts[i].toISOString(), end: ends[i].toISOString(),
        allDay: allDay[i], location: where[i] || '', calendar: name }))
    }
    out.sort((a, b) => a.start.localeCompare(b.start))
    return out.slice(0, input.limit || 60)
"""#

    public static let createEvent = #"""

    const Cal = Application('Calendar')
    let cal = null
    if (input.calendar) {
      cal = Cal.calendars().find((c) => c.name() === input.calendar)
      if (!cal) throw new Error('There is no calendar called ' + input.calendar)
    } else {
      cal = Cal.calendars().find((c) => c.writable())
      if (!cal) throw new Error('There is no calendar Merry can add to')
    }
    const ev = Cal.Event({ summary: input.title, startDate: new Date(input.start), endDate: new Date(input.end),
      alldayEvent: !!input.allDay, location: input.location || '', description: input.notes || '' })
    cal.events.push(ev)
    return { id: ev.uid(), calendar: cal.name() }
"""#

    public static let eventExists = #"""

    const Cal = Application('Calendar')
    for (const c of Cal.calendars()) {
      const hit = c.events.whose({ uid: input.id })()
      if (hit.length) return { found: true, title: hit[0].summary(), start: hit[0].startDate().toISOString(), calendar: c.name() }
    }
    return { found: false }
"""#

    public static let deleteEvent = #"""

    const Cal = Application('Calendar')
    for (const c of Cal.calendars()) {
      const hit = c.events.whose({ uid: input.id })()
      if (hit.length) { Cal.delete(hit[0]); return { deleted: true } }
    }
    return { deleted: false }
"""#

    public static let reminderLists = #"""
return Application('Reminders').lists.name()
"""#

    public static let reminders = #"""

    const R = Application('Reminders')
    const lists = input.list ? R.lists().filter((l) => l.name() === input.list) : R.lists()
    const out = []
    for (const l of lists) {
      const q = l.reminders.whose({ completed: false })
      const ids = q.id()
      if (!ids.length) continue
      const names = q.name(), dues = q.dueDate(), listName = l.name()
      ids.forEach((id, i) => out.push({ id, title: names[i], due: dues[i] ? dues[i].toISOString() : null, list: listName }))
    }
    return out.slice(0, input.limit || 100)
"""#

    public static let createReminder = #"""

    const R = Application('Reminders')
    let list = R.defaultList()
    if (input.list) {
      list = R.lists().find((l) => l.name() === input.list)
      if (!list) throw new Error('There is no Reminders list called ' + input.list)
    }
    const props = { name: input.title }
    if (input.due) props.dueDate = new Date(input.due)
    if (input.notes) props.body = input.notes
    const r = R.Reminder(props)
    list.reminders.push(r)
    return { id: r.id(), list: list.name() }
"""#

    public static let reminderExists = #"""

    const R = Application('Reminders')
    try { const r = R.reminders.byId(input.id); return { found: true, title: r.name(), completed: r.completed() } }
    catch (e) { return { found: false } }
"""#

    public static let deleteReminder = #"""

    const R = Application('Reminders')
    try { R.delete(R.reminders.byId(input.id)); return { deleted: true } } catch (e) { return { deleted: false } }
"""#

    public static let completeReminder = #"""

    const R = Application('Reminders')
    const r = R.reminders.byId(input.id)
    r.completed = input.completed !== false
    return { completed: r.completed() }
"""#

    public static let createNote = #"""

    const N = Application('Notes')
    let folder = N.defaultAccount().defaultFolder()
    if (input.folder) {
      folder = N.folders().find((f) => f.name() === input.folder)
      if (!folder) throw new Error('There is no Notes folder called ' + input.folder)
    }
    const n = N.Note({ body: input.html })
    folder.notes.push(n)
    return { id: n.id(), name: n.name(), folder: folder.name() }
"""#

    public static let searchNotes = #"""

    const N = Application('Notes')
    const q = N.notes.whose({ _or: [{ name: { _contains: input.query } }, { plaintext: { _contains: input.query } }] })
    const ids = q.id()
    const names = q.name(), mods = q.modificationDate()
    return ids.map((id, i) => ({ id, title: names[i], modified: mods[i].toISOString() }))
      .sort((a, b) => b.modified.localeCompare(a.modified)).slice(0, input.limit || 10)
"""#

    public static let readNote = #"""

    const n = Application('Notes').notes.byId(input.id)
    return { title: n.name(), text: n.plaintext().slice(0, input.maxChars || 20000) }
"""#

    public static let noteExists = #"""

    try { const n = Application('Notes').notes.byId(input.id); return { found: true, title: n.name() } } catch (e) { return { found: false } }
"""#

    public static let deleteNote = #"""

    const N = Application('Notes')
    try { N.delete(N.notes.byId(input.id)); return { deleted: true } } catch (e) { return { deleted: false } }
"""#

    public static let mailDraft = #"""

    const M = Application('Mail')
    const msg = M.OutgoingMessage({ subject: input.subject, content: input.body, visible: true })
    M.outgoingMessages.push(msg)
    for (const address of input.to || []) msg.toRecipients.push(M.Recipient({ address }))
    for (const address of input.cc || []) msg.ccRecipients.push(M.CcRecipient({ address }))
    M.activate()
    return { opened: true }
"""#

    public static let runningApps = #"""

    const se = Application('System Events')
    const q = se.processes.whose({ backgroundOnly: false })
    return q.name()
"""#

    public static let browserTabs = #"""

    const se = Application('System Events')
    const running = se.processes.whose({ backgroundOnly: false }).name()
    const out = []
    for (const name of ['Google Chrome', 'Arc', 'Brave Browser', 'Microsoft Edge', 'Chromium']) {
      if (!running.includes(name)) continue
      try {
        Application(name).windows().forEach((w, wi) => {
          const active = w.activeTab().id()
          w.tabs().forEach((t) => {
            const isActive = t.id() === active
            if (!input.activeOnly || (isActive && wi === 0)) out.push({ browser: name, title: t.title(), url: t.url(), active: isActive && wi === 0 })
          })
        })
      } catch (e) {}
    }
    if (running.includes('Safari')) {
      try {
        Application('Safari').windows().forEach((w, wi) => {
          const current = w.currentTab().index()
          w.tabs().forEach((t) => {
            const isActive = t.index() === current
            if (!input.activeOnly || (isActive && wi === 0)) out.push({ browser: 'Safari', title: t.name(), url: t.url(), active: isActive && wi === 0 })
          })
        })
      } catch (e) {}
    }
    return out.slice(0, 200)
"""#

    // The page open in the person's own browser: title, address, selection and
    // main text. Read-only, and the script run in the page is fixed text below,
    // never built from a request.
    public static let readTab = #"""

    const se = Application('System Events')
    const running = se.processes.whose({ backgroundOnly: false }).name()
    const js = "(function(){var m=document.querySelector('article')||document.querySelector('main,[role=main]')||document.body;" +
      "return JSON.stringify({title:document.title,url:location.href,selection:String(window.getSelection()||'').slice(0,8000)," +
      "text:((m&&m.innerText)||'').replace(/\n{3,}/g,'\n\n').slice(0,40000)})})()"
    const browsers = ['Google Chrome', 'Arc', 'Brave Browser', 'Microsoft Edge', 'Chromium', 'Safari']
    const order = input.prefer && browsers.includes(input.prefer) ? [input.prefer, ...browsers.filter((b) => b !== input.prefer)] : browsers
    for (const name of order) {
      if (!running.includes(name)) continue
      let raw
      if (name === 'Safari') {
        const s = Application('Safari')
        if (!s.documents.length) continue
        raw = s.doJavaScript(js, { in: s.documents[0] })
      } else {
        const app = Application(name)
        if (!app.windows.length) continue
        raw = app.windows[0].activeTab().execute({ javascript: js })
      }
      const page = JSON.parse(raw)
      return { browser: name, title: page.title, url: page.url, selection: page.selection, text: page.text }
    }
    return null
"""#

    // Runs one of Merry's fixed page programs in the active tab of the person's
    // browser. `program` is always one of the constants in YourBrowserTools.swift and
    // `arg` is JSON-encoded data; neither is ever text from a model or a page.
    public static let pageRun = #"""

    const se = Application('System Events')
    const running = se.processes.whose({ backgroundOnly: false }).name()
    const browsers = ['Google Chrome', 'Brave Browser', 'Microsoft Edge', 'Chromium', 'Arc', 'Safari']
    const name = input.browser && running.includes(input.browser) ? input.browser : browsers.find((b) => running.includes(b))
    if (!name) throw new Error('No supported browser is running.')
    const code = '(' + input.program + ')(' + input.arg + ')'
    let raw
    if (name === 'Safari') {
      const s = Application('Safari')
      raw = s.doJavaScript(code, { in: s.windows[0].currentTab() })
    } else {
      raw = Application(name).windows[0].activeTab().execute({ javascript: code })
    }
    return { browser: name, result: raw === undefined || raw === null || raw === '' ? null : JSON.parse(raw) }
"""#

    // A new tab in the person's browser, brought to the front. Their current
    // tab is left exactly as it was.
    public static let newTab = #"""

    const name = input.browser
    const app = Application(name)
    app.activate()
    if (name === 'Safari') {
      if (!app.windows.length) app.Document().make()
      const w = app.windows[0]
      const t = app.Tab({ url: input.url })
      w.tabs.push(t)
      w.currentTab = t
      return { browser: name }
    }
    if (!app.windows.length) {
      app.Window().make()
      app.windows[0].activeTab().url = input.url
      return { browser: name }
    }
    const w = app.windows[0]
    w.tabs.push(app.Tab({ url: input.url }))
    w.activeTabIndex = w.tabs.length
    return { browser: name }
"""#

    // Selected text in the app the person was using. Needs Accessibility.
    public static let selection = #"""

    const se = Application('System Events')
    try {
      const p = se.processes.byName(input.app)
      const el = p.attributes.byName('AXFocusedUIElement').value()
      const text = el.attributes.byName('AXSelectedText').value()
      return typeof text === 'string' ? text.slice(0, 20000) : null
    } catch (e) { return null }
"""#

    public static let finderSelection = #"""

    const se = Application('System Events')
    if (!se.processes.name().includes('Finder')) return []
    return Application('Finder').selection().map((i) => decodeURI(i.url()).replace(/^file:\/\//, '').replace(/\/$/, ''))
"""#

    public static let appearance = #"""

    const se = Application('System Events')
    const previous = se.appearancePreferences.darkMode()
    if (typeof input.dark === 'boolean') se.appearancePreferences.darkMode = input.dark
    return { previous, now: se.appearancePreferences.darkMode() }
"""#

    public static let volume = #"""

    const app = Application.currentApplication()
    app.includeStandardAdditions = true
    const before = app.getVolumeSettings()
    if (typeof input.volume === 'number') app.setVolume(null, { outputVolume: Math.max(0, Math.min(100, Math.round(input.volume))) })
    if (typeof input.muted === 'boolean') app.setVolume(null, { outputMuted: input.muted })
    const after = app.getVolumeSettings()
    return { previousVolume: before.outputVolume, previousMuted: before.outputMuted, volume: after.outputVolume, muted: after.outputMuted }
"""#

    public static let quitApp = #"""

    const a = Application(input.app)
    if (!a.running()) return { quit: false, reason: 'not running' }
    a.quit()
    return { quit: true }
"""#

    /// Every script with its name, in the order they are declared.
    public static let all: [(name: String, body: String)] = [
        ("calendars", calendars), ("events", events), ("createEvent", createEvent), ("eventExists", eventExists), ("deleteEvent", deleteEvent),
        ("reminderLists", reminderLists), ("reminders", reminders), ("createReminder", createReminder), ("reminderExists", reminderExists),
        ("deleteReminder", deleteReminder), ("completeReminder", completeReminder),
        ("createNote", createNote), ("searchNotes", searchNotes), ("readNote", readNote), ("noteExists", noteExists), ("deleteNote", deleteNote),
        ("mailDraft", mailDraft), ("runningApps", runningApps), ("browserTabs", browserTabs), ("readTab", readTab), ("pageRun", pageRun), ("newTab", newTab),
        ("selection", selection), ("finderSelection", finderSelection), ("appearance", appearance), ("volume", volume), ("quitApp", quitApp)
    ]

    /// The name of a script, given its text.
    public static func name(of body: String) -> String? { all.first { $0.body == body }?.name }
}

/* ------------------------------------------------------------------ *
 * Undo for app items and settings.
 * ------------------------------------------------------------------ */

public enum MacUndoKind: String, Codable, Sendable {
    case event = "mac.event"
    case reminder = "mac.reminder"
    case note = "mac.note"
    case setting = "mac.setting"

    /// The app-change kinds among all undo kinds; nil for file operations.
    public init?(_ kind: UndoEntry.Kind) { self.init(rawValue: kind.rawValue) }
}

public struct MacUndoResult: Equatable, Sendable {
    public var ok: Bool
    /// Why it declined, when it did.
    public var reason: String?
    public init(ok: Bool, reason: String? = nil) { self.ok = ok; self.reason = reason }
}

/// Reverses one app change. Items are identified by the id the app gave them;
/// settings carry their previous value. Returns a reason when it declines.
public func reverseMacChange(_ kind: MacUndoKind, _ payload: UndoEntry.Payload, bridge: MacBridge? = nil) async -> MacUndoResult {
    let b = bridge ?? macBridge()
    do {
        switch kind {
        case .event:
            let r = try await b.jxa(SCRIPTS.deleteEvent, ["id": .string(payload.to)])
            return jsTruthy(r["deleted"]) ? MacUndoResult(ok: true) : MacUndoResult(ok: false, reason: "the event is already gone")
        case .reminder:
            let r = try await b.jxa(SCRIPTS.deleteReminder, ["id": .string(payload.to)])
            return jsTruthy(r["deleted"]) ? MacUndoResult(ok: true) : MacUndoResult(ok: false, reason: "the reminder is already gone")
        case .note:
            let r = try await b.jxa(SCRIPTS.deleteNote, ["id": .string(payload.to)])
            return jsTruthy(r["deleted"]) ? MacUndoResult(ok: true) : MacUndoResult(ok: false, reason: "the note is already gone")
        case .setting:
            // mac.setting: `from` names the setting, `to` holds its previous value.
            if payload.from == "dark" {
                _ = try await b.jxa(SCRIPTS.appearance, ["dark": .bool(payload.to == "true")])
            } else if payload.from == "volume" {
                _ = try await b.jxa(SCRIPTS.volume, ["volume": .number(jsNumber(payload.to))])
            } else if payload.from == "muted" {
                _ = try await b.jxa(SCRIPTS.volume, ["muted": .bool(payload.to == "true")])
            } else {
                return MacUndoResult(ok: false, reason: "unknown setting \(payload.from)")
            }
            return MacUndoResult(ok: true)
        }
    } catch {
        return MacUndoResult(ok: false, reason: messageOf(error))
    }
}

/// Reverses a recorded undo entry, when it is an app change.
public func reverseMacChange(_ entry: UndoEntry, bridge: MacBridge? = nil) async -> MacUndoResult {
    guard let kind = MacUndoKind(entry.kind) else { return MacUndoResult(ok: false, reason: "not an app change") }
    return await reverseMacChange(kind, entry.payload, bridge: bridge)
}

// MARK: - JavaScript value rules the tools built on these scripts rely on

/// `Number(text)` for the decimal forms a stored setting can take; anything else is NaN.
func jsNumber(_ text: String) -> Double {
    let t = text.jsTrimmed
    if t.isEmpty { return 0 }
    guard Rx(#"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#).test(t) else { return .nan }
    return Double(t) ?? .nan
}

/// JavaScript's truthiness, for values a script handed back.
func jsTruthy(_ value: JSON?) -> Bool {
    switch value {
    case nil, .null?: return false
    case .bool(let b)?: return b
    case .number(let n)?: return n != 0 && !n.isNaN
    case .string(let s)?: return !s.isEmpty
    case .array?, .object?: return true
    }
}

/// `String(value)` for the plain values a script hands back.
func jsString(_ value: JSON?) -> String {
    switch value {
    case nil: return "undefined"
    case .null?: return "null"
    case .bool(let b)?: return b ? "true" : "false"
    case .number(let n)?: return n.isNaN ? "NaN" : n.isInfinite ? (n < 0 ? "-Infinity" : "Infinity") : JSON.format(n)
    case .string(let s)?: return s
    case .array(let a)?: return a.map { $0.isNull ? "" : jsString($0) }.joined(separator: ",")
    case .object?: return "[object Object]"
    }
}
