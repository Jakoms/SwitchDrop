import Cocoa
import SwiftUI
import UniformTypeIdentifiers

let mint = Color(red: 0.35, green: 0.94, blue: 0.72)
let panelColor = Color(red: 0.085, green: 0.10, blue: 0.12)
let muted = Color(red: 0.57, green: 0.62, blue: 0.67)
func bytes(_ n: Int64) -> String {
    let units = UI.language == .ru ? ["Б", "КБ", "МБ", "ГБ", "ТБ"] : ["B", "KB", "MB", "GB", "TB"]
    var value = Double(max(0, n)); var index = 0
    while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
    let text = String(format: value < 10 && index > 0 ? "%.1f" : "%.0f", value).replacingOccurrences(of: ".", with: UI.language == .ru ? "," : ".")
    return "\(text) \(units[index])"
}
let formats: Set<String> = ["nsp", "nsz", "xci", "xcz"]

enum JobState: String, Codable {
    case queued, sending, sent, failed, cancelled, interrupted
    var title: String {
        switch self {
        case .queued: return l("В очереди","Queued")
        case .sending: return l("Передача","Transferring")
        case .sent: return l("Передано в DBI","Sent to DBI")
        case .failed: return l("Ошибка","Failed")
        case .cancelled: return l("Остановлено","Stopped")
        case .interrupted: return l("Передача была прервана","Interrupted")
        }
    }
}
struct Job: Identifiable, Codable {
    var id = UUID()
    var path: String
    var size: Int64
    var state: JobState = .queued
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct Device: Identifiable {
    let bus: Int, dev: Int, product: Int, storage: Int
    let serial: String, label: String
    let free: Int64, capacity: Int64
    var id: String { "\(bus):\(dev):\(storage)" }
}
// JSON events may be split across arbitrary pipe reads, including inside UTF-8.
struct EventDecoder {
    var buffer = Data()
    mutating func feed(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var events = [[String: Any]]()
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            if let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { events.append(e) }
        }
        return events
    }
}

func encodeCommand(_ args: [String]) -> Data {
    var payload = Data()
    for arg in args { payload.append(contentsOf: arg.utf8); payload.append(0) }
    var length = UInt32(payload.count).bigEndian
    var framed = withUnsafeBytes(of: &length) { Data($0) }
    framed.append(payload)
    return framed
}

final class Store: ObservableObject {
    @Published var language = UI.language {
        didSet { UI.language = language; UserDefaults.standard.set(language.rawValue, forKey: "language"); NotificationCenter.default.post(name: Notification.Name("LanguageChanged"), object: nil) }
    }
    @Published var viewMode = "files"
    @Published var remoteStorages: [RemoteStorage] = []
    @Published var browserStorageID = 0
    @Published var browserPath: [RemoteLocation] = []
    @Published var entries: [RemoteEntry] = []
    @Published var selectedEntryID: Int?
    @Published var search = ""
    @Published var fsActive = false
    @Published var currentName = ""
    var fsCommand = ""
    @Published var jobs: [Job] = []
    @Published var devices: [Device] = []
    @Published var selected = ""
    @Published var busy = false
    @Published var transferring = false
    @Published var stopping = false
    @Published var status = "Подключите Switch и запустите MTP в DBI"
    @Published var problem = ""
    @Published var logs: [String] = []
    @Published var sent: Int64 = 0
    @Published var currentSize: Int64 = 0
    @Published var speed: Double = 0
    @Published var activeID: UUID?
    @Published var dropActive = false
    private var process: Process?
    private var commandInput: FileHandle?
    private var sessionReady = false
    private var activeJobs: [UUID] = []
    private var lastSample = Date()
    private var lastSent: Int64 = 0
    private var activity: NSObjectProtocol?
    private var operation = UUID()
    private var gotError = false
    private var gotDone = false
    private var gotCancelled = false
    let stateURL: URL
    init(stateURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SwitchDrop")
        self.stateURL = stateURL ?? base.appendingPathComponent("queue.json")
        if let data = try? Data(contentsOf: self.stateURL), let saved = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = saved.map { var j = $0; if j.state == .sending { j.state = .interrupted }; return j }
        }
    }
    var device: Device? { devices.first { $0.id == selected } }
    var pending: [Job] { jobs.filter { $0.state == .queued } }
    var total: Int64 { pending.reduce(0) { $0 + $1.size } }
    var ready: Bool { !busy && (device?.storage ?? 0) != 0 && !pending.isEmpty }
    var progress: Double { currentSize > 0 ? min(1, Double(sent) / Double(currentSize)) : 0 }
    var eta: String {
        guard speed > 1, currentSize > sent else { return "—" }
        let seconds = Int(Double(currentSize - sent) / speed)
        return seconds >= 60 ? l("\(seconds / 60) мин \(seconds % 60) с", "\(seconds / 60)m \(seconds % 60)s") : l("\(seconds) с", "\(seconds)s")
    }
    func persist() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: stateURL, options: .atomic)
        } catch { problem = l("Не удалось сохранить очередь: \(error.localizedDescription)","Could not save queue: \(error.localizedDescription)") }
    }
    func log(_ text: String) {
        logs.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? logs.joined(separator: "\n").write(to: stateURL.deletingLastPathComponent().appendingPathComponent("session.log"), atomically: true, encoding: .utf8)
    }
    func add(_ urls: [URL]) {
        guard !transferring else { return }
        var rejected = [String]()
        for url in urls {
            let u = url.standardizedFileURL
            guard u.isFileURL, formats.contains(u.pathExtension.lowercased()),
                  let a = try? FileManager.default.attributesOfItem(atPath: u.path),
                  a[.type] as? FileAttributeType == .typeRegular,
                  let size = (a[.size] as? NSNumber)?.int64Value, size > 0,
                  FileManager.default.isReadableFile(atPath: u.path) else { rejected.append(u.lastPathComponent); continue }
            if jobs.contains(where: { $0.path == u.path }) { continue }
            jobs.append(Job(path: u.path, size: size))
        }
        if !rejected.isEmpty { problem = l("Не добавлены: \(rejected.prefix(5).joined(separator: ", ")). Нужны непустые файлы NSP, NSZ, XCI или XCZ.","Not added: \(rejected.prefix(5).joined(separator: ", ")). Choose non-empty NSP, NSZ, XCI or XCZ files.") }
        persist()
    }
    func chooseFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = formats.compactMap { UTType(filenameExtension: $0) }
        p.prompt = l("Добавить","Add"); p.message = l("Выберите игры, обновления или DLC","Choose games, updates or DLC")
        if p.runModal() == .OK { add(p.urls) }
    }
    func remove(_ id: UUID) { guard !busy else { return }; jobs.removeAll { $0.id == id }; persist() }
    func retry(_ id: UUID) {
        guard !busy, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = .queued; persist()
    }
    func clearFinished() { guard !busy else { return }; jobs.removeAll { $0.state == .sent }; persist() }
    func scan() {
        guard !busy else { return }
        if sessionReady, let p = process, p.isRunning {
            status = "Switch подключён · MTP-сессия открыта"
            return
        }
        devices = []; selected = ""; remoteStorages = []; browserStorageID = 0; browserPath = []; entries = []; problem = ""; status = "Ищу Switch…"
        run(["session"], transfer: false)
    }
    func start() {
        guard ready, let d = device else { return }
        problem = ""
        let list = pending
        // Validate all files before opening a write session; helper checks again using fstat.
        for j in list {
            guard let a = try? FileManager.default.attributesOfItem(atPath: j.path),
                  a[.type] as? FileAttributeType == .typeRegular,
                  (a[.size] as? NSNumber)?.int64Value == j.size,
                  FileManager.default.isReadableFile(atPath: j.path) else {
                problem = l("Файл изменился или недоступен: \(j.name). Удалите его из очереди и добавьте заново.","File changed or unavailable: \(j.name). Remove it from the queue and add it again."); return
            }
        }
        activeJobs = list.map(\.id); activeID = nil; sent = 0; currentSize = 0; speed = 0
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Передача игр в DBI")
        guard sessionReady, let p = process, p.isRunning, let input = commandInput else {
            problem = l("MTP-сессия закрыта. Перезапустите MTP Responder в DBI и обновите подключение.","The MTP session is closed. Restart MTP Responder in DBI and reconnect.")
            devices = []; selected = ""; endActivity(); return
        }
        let command = encodeCommand(["send", String(d.storage)] + list.map(\.path))
        guard command.count <= 4 * 1024 * 1024 + 4 else { problem = l("Слишком большая очередь. Передайте файлы несколькими партиями.","The queue is too large. Transfer it in smaller batches."); endActivity(); return }
        gotDone = false; gotError = false; gotCancelled = false
        busy = true; transferring = true; stopping = false
        status = "Начинаю передачу в открытой MTP-сессии…"
        log("Передача через существующую MTP-сессию: \(list.count) файлов")
        do { try input.write(contentsOf: command) }
        catch {
            problem = l("Не удалось отправить команду MTP: \(error.localizedDescription)","Could not send MTP command: \(error.localizedDescription)")
            busy = false; transferring = false; devices = []; selected = ""; endActivity()
            try? input.close(); commandInput = nil
        }
    }
    func requestFS(_ args: [String], transfer: Bool) {
        guard !busy else { return }
        guard sessionReady, let p = process, p.isRunning, let input = commandInput else { problem = l("Сначала подключите Switch.", "Connect your Switch first."); return }
        let command = encodeCommand(args)
        guard command.count <= 4 * 1024 * 1024 + 4 else { problem = l("Слишком много файлов. Загрузите их несколькими партиями.","Too many files. Upload them in smaller batches."); return }
        problem = ""; fsCommand = args[0]; fsActive = true; busy = true; transferring = transfer; stopping = false
        activeJobs = []; activeID = nil; sent = 0; currentSize = 0; speed = 0; currentName = ""
        gotError = false; gotDone = false; gotCancelled = false
        status = transfer ? l("Передача файлов…", "Transferring files…") : l("Чтение / изменение папки…", "Reading / updating folder…")
        if transfer { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated,.idleSystemSleepDisabled], reason: "SwitchDrop file transfer") }
        do { try input.write(contentsOf: command) }
        catch { problem = error.localizedDescription; busy = false; transferring = false; fsActive = false; endActivity() }
    }
    func cancel() {
        guard busy, !stopping, let p = process, p.isRunning else { return }
        stopping = true; status = "Останавливаю… Дождитесь ответа DBI"
        kill(p.processIdentifier, SIGUSR1)
        log("Запрошена отмена. Текущая установка могла успеть завершиться; проверьте DBI.")
    }
    func event(_ e: [String: Any]) {
        let type = e["type"] as? String ?? ""
        let msg = e["message"] as? String ?? ""
        let index = e["index"] as? Int ?? -1
        let id = activeJobs.indices.contains(index) ? activeJobs[index] : nil
        switch type {
        case "device":
            guard let bus=e["bus"] as? Int, let dev=e["dev"] as? Int, let product=e["product"] as? Int,
                  let storage=e["storage"] as? Int else { return }
            let d = Device(bus: bus, dev: dev, product: product, storage: storage, serial: e["serial"] as? String ?? "", label: e["label"] as? String ?? "", free: (e["free"] as? NSNumber)?.int64Value ?? 0, capacity: (e["capacity"] as? NSNumber)?.int64Value ?? 0)
            devices.append(d); if selected.isEmpty { selected = d.id }
        case "storage":
            if let id=e["id"] as? Int {
                remoteStorages.append(RemoteStorage(id:id,label:e["label"] as? String ?? "",writable:e["writable"] as? Bool ?? false,install:e["install"] as? Bool ?? false,free:(e["free"] as? NSNumber)?.int64Value ?? 0))
            }
        case "ready":
            sessionReady = true; busy = false; status = msg; log(msg)
            browserStorageID = remoteStorages.first(where:{$0.writable})?.id ?? remoteStorages.first(where:{!$0.install})?.id ?? 0
            if viewMode == "files" { DispatchQueue.main.async { self.loadFolder() } }
        case "listbegin": entries = []
        case "entry":
            if let id=e["id"] as? Int, let storage=e["storage"] as? Int {
                entries.append(RemoteEntry(id:id,parent:e["parent"] as? Int ?? mtpRoot,storage:storage,name:e["name"] as? String ?? "",folder:e["folder"] as? Bool ?? false,size:(e["size"] as? NSNumber)?.int64Value ?? 0))
            }
        case "fsstart":
            currentName=e["name"] as? String ?? ""; currentSize=(e["size"] as? NSNumber)?.int64Value ?? 0
            sent=0; speed=0; lastSent=0; lastSample=Date(); log(currentName)
        case "fsdone":
            let refresh = fsCommand != "list"
            gotDone=true; busy=false; transferring=false; fsActive=false; stopping=false; speed=0
            status = refresh ? "File operation complete" : "Folder loaded"; endActivity()
            if refresh { log(status); DispatchQueue.main.async { self.loadFolder() } }
        case "operror":
            gotError=true; busy=false; transferring=false; fsActive=false; stopping=false; problem=msg; status=msg; log(msg); endActivity()
        case "batchdone":
            gotDone = true; busy = false; transferring = false; stopping = false
            activeID = nil; speed = 0; status = msg; log(msg); persist(); endActivity()
        case "closed":
            gotDone = true; status = msg; log(msg)
        case "start":
            activeID = id; sent = 0; speed = 0; currentSize = (e["size"] as? NSNumber)?.int64Value ?? 0
            lastSample = Date(); lastSent = 0
            if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = .sending; status = "Передача \(index + 1) из \(activeJobs.count)"; log("Отправка: \(jobs[i].name)"); persist() }
        case "progress":
            guard fsActive || id == activeID else { return }
            sent = min(currentSize, (e["sent"] as? NSNumber)?.int64Value ?? 0)
            let elapsed = Date().timeIntervalSince(lastSample)
            if elapsed > 0.4 {
                let sample = Double(max(0, sent - lastSent)) / elapsed
                speed = speed == 0 ? sample : speed * 0.65 + sample * 0.35
                lastSample = Date(); lastSent = sent
            }
            if sent >= currentSize { status = fsActive ? l("Завершение операции…","Finalizing operation…") : "DBI завершает обработку файла…" }
        case "sent":
            if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = .sent; sent = currentSize; log("Передано в DBI: \(jobs[i].name)"); persist() }
        case "error": gotError = true; problem = msg; log(msg)
        case "detail": log(msg)
        case "cancelled": gotCancelled = true; status = msg; log(msg)
        case "done": gotDone = true; status = msg; log(msg)
        default: break
        }
    }
    func run(_ arguments: [String], transfer: Bool) {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "mtp-helper") else { problem = l("В приложении отсутствует MTP-модуль.","The MTP helper is missing from the application."); endActivity(); return }
        let p = Process(); p.executableURL = helper; p.arguments = arguments
        let output = Pipe(), error = Pipe(); p.standardOutput = output; p.standardError = error
        let input = Pipe(); p.standardInput = input
        commandInput = input.fileHandleForWriting; sessionReady = false
        let token = UUID(); operation = token
        gotError = false; gotDone = false; gotCancelled = false
        do { try p.run() } catch { problem = error.localizedDescription; endActivity(); return }
        process = p; busy = true; transferring = transfer; stopping = false
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var decoder = EventDecoder()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                for e in decoder.feed(data) { DispatchQueue.main.async { if self.operation == token { self.event(e) } } }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var tail = Data()
            while true {
                let d = error.fileHandleForReading.availableData
                if d.isEmpty { break }
                tail.append(d); if tail.count > 24_000 { tail = tail.suffix(24_000) }
            }
            let text = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { DispatchQueue.main.async { if self.operation == token { self.log(text) } } }
            group.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            p.waitUntilExit(); group.wait()
            DispatchQueue.main.async { if self.operation == token { self.finished(p.terminationStatus, transfer: self.transferring) } }
        }
        if !transfer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                if self.operation == token && !self.sessionReady && p.isRunning {
                    self.gotError = true; self.problem = l("Switch не отвечает. Закройте OpenMTP, перезапустите MTP в DBI и проверьте USB-кабель.","Switch is not responding. Quit OpenMTP, restart MTP in DBI and check the USB cable.")
                    kill(p.processIdentifier, SIGKILL) // scan is read-only
                }
            }
        }
    }
    func finished(_ exit: Int32, transfer: Bool) {
        for i in jobs.indices where jobs[i].state == .sending {
            jobs[i].state = (gotCancelled || stopping) ? .cancelled : .failed
        }
        if !gotDone && !gotCancelled && !gotError {
            problem = l("MTP-модуль завершился без подтверждения (код \(exit)). Проверьте DBI и обновите подключение.","The MTP helper exited without confirmation (code \(exit)). Check DBI and reconnect.")
        }
        if !transfer && !devices.isEmpty { status = "Switch подключён · установка на SD" }
        if gotError { status = "\(transfer ? "Передача остановлена" : "Подключение не готово")" }
        busy = false; transferring = false; stopping = false; process = nil; activeID = nil; speed = 0
        persist(); endActivity()
        sessionReady = false; devices = []; selected = ""; remoteStorages = []; fsActive = false
        try? commandInput?.close(); commandInput = nil
    }
    func disconnect() {
        guard !transferring else { return }
        if let input = commandInput { try? input.write(contentsOf: encodeCommand(["quit"])); try? input.close() }
        commandInput = nil
    }
    func endActivity() { if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil } }
    func saveLog() {
        let p = NSSavePanel(); p.nameFieldStringValue = "SwitchDrop-log.txt"
        if p.runModal() == .OK, let url = p.url {
            do { try logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
            catch { problem = error.localizedDescription }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Store
    @State private var showLog = false
    var body: some View {
        HStack(spacing:0) {
            sidebar.frame(width:230)
            VStack(alignment:.leading,spacing:18) {
                HStack {
                    VStack(alignment:.leading,spacing:6) {
                        Text(model.viewMode=="files" ? l("Файлы на Switch","Switch files"):l("Игры → Switch","Games → Switch")).font(.system(size:28,weight:.bold))
                        Text("USB / MTP  ·  DBI").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(1.6).foregroundStyle(muted)
                    }
                    Spacer()
                    Button { model.language = model.language == .ru ? .en : .ru } label: {
                        HStack(spacing:5){ Image(systemName:"globe");Text(model.language == .ru ? "RU":"EN").font(.system(size:11,weight:.bold,design:.monospaced)) }.padding(8)
                    }.buttonStyle(.plain).background(Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:8)).help(l("Переключить на английский","Switch to Russian"))
                    Button {showLog=true} label:{Image(systemName:"text.alignleft").font(.system(size:17)).padding(8)}.buttonStyle(.plain).help(l("Журнал","Log"))
                }
                if !model.problem.isEmpty {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(browserMessage(translated(model.problem))).font(.system(size:12)).textSelection(.enabled)
                        Spacer(minLength:0)
                        Button {model.problem=""} label:{Image(systemName:"xmark")}.buttonStyle(.plain)
                    }.padding(12).background(Color.orange.opacity(0.09),in:RoundedRectangle(cornerRadius:10))
                }
                if model.viewMode=="files" { FileBrowserView(model:model) }
                else { games }
                footer
            }.padding(25).frame(maxWidth:.infinity,maxHeight:.infinity)
        }.foregroundStyle(Color.white.opacity(0.92))
        .background(Color(red:0.055,green:0.065,blue:0.08)).preferredColorScheme(.dark)
        .sheet(isPresented:$showLog) {
            VStack(alignment:.leading,spacing:15) {
                HStack {Text(l("Журнал","Log")).font(.title2.bold());Spacer();Button(l("Сохранить…","Save…")){model.saveLog()};Button(l("Закрыть","Close")){showLog=false}}
                ScrollView {Text(model.logs.isEmpty ? l("Пока нет событий","No events yet"):model.logs.joined(separator:"\n")).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
            }.padding(24).frame(width:690,height:420)
        }
    }
    var sidebar: some View {
        VStack(alignment:.leading,spacing:24) {
            HStack(spacing:10) {Image(systemName:"arrow.down.forward.circle.fill").font(.system(size:30)).foregroundStyle(mint);Text("SwitchDrop").font(.system(size:18,weight:.bold))}
            VStack(spacing:6) {
                tab("files",l("Файлы","Files"),"folder")
                tab("games",l("Игры","Games"),"gamecontroller")
            }
            VStack(alignment:.leading,spacing:12) {
                HStack {Circle().fill(model.device==nil ? Color.orange:mint).frame(width:7,height:7);Text(model.device==nil ? l("НЕТ ПОДКЛЮЧЕНИЯ","NOT CONNECTED"):l("SWITCH ПОДКЛЮЧЁН","SWITCH CONNECTED")).font(.system(size:9,weight:.bold,design:.monospaced))}
                Text("DBI → MTP Responder").font(.system(size:13,weight:.semibold))
                Text(model.device==nil ? l("Подключите консоль USB-кабелем с передачей данных.","Connect your console with a USB data cable."):l("Одна сессия для файлов и игр.","One session for files and games.")).font(.system(size:11)).foregroundStyle(muted).lineSpacing(3)
                Button {model.scan()} label:{HStack {Image(systemName:"arrow.clockwise");Text(l("Подключиться","Connect"))}.font(.system(size:12)).frame(maxWidth:.infinity).padding(.vertical,8)}.buttonStyle(.plain).background(Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:8)).disabled(model.busy)
            }.padding(14).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            if !model.remoteStorages.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    Text(l("ХРАНИЛИЩА","STORAGES")).font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1).foregroundStyle(muted)
                    ForEach(model.remoteStorages.filter{!$0.install}) { storage in
                        Button {model.viewMode="files";model.selectStorage(storage.id)} label:{HStack(spacing:8){Image(systemName:storage.writable ? "sdcard":"externaldrive");Text(storage.label).lineLimit(1);Spacer()}.font(.system(size:11)).foregroundStyle(model.browserStorageID==storage.id ? mint:muted)}.buttonStyle(.plain).disabled(model.busy)
                    }
                }
            }
            Spacer(minLength:0)
            Text(l("Закройте OpenMTP и Android File Transfer перед подключением.","Quit OpenMTP and Android File Transfer before connecting.")).font(.system(size:10)).foregroundStyle(muted).lineSpacing(3)
            Text("SWITCHDROP 2.0").font(.system(size:9,design:.monospaced)).tracking(1.4).foregroundStyle(muted.opacity(0.6))
        }.padding(20).frame(maxHeight:.infinity).background(panelColor)
    }
    func tab(_ id:String,_ title:String,_ icon:String)->some View {
        Button { if id=="files" {model.showFiles()} else{model.viewMode=id} } label:{HStack(spacing:10){Image(systemName:icon).frame(width:18);Text(title).font(.system(size:13,weight:.semibold));Spacer()}.padding(11).foregroundStyle(model.viewMode==id ? mint:muted)}.buttonStyle(.plain).background(model.viewMode==id ? mint.opacity(0.08):Color.clear,in:RoundedRectangle(cornerRadius:9))
    }
    var games: some View {
        VStack(alignment:.leading,spacing:15) {
            VStack(spacing:10) {
                Image(systemName:"square.and.arrow.down").font(.system(size:27,weight:.light)).foregroundStyle(mint)
                Text(l("Перетащите файлы игр сюда","Drop game packages here")).font(.system(size:17,weight:.semibold))
                HStack(spacing:10) {Text("NSP / NSZ / XCI / XCZ").font(.system(size:10,design:.monospaced)).foregroundStyle(muted);Button(l("Выбрать файлы…","Choose files…")){model.chooseFiles()}.buttonStyle(.plain).foregroundStyle(mint).font(.system(size:12,weight:.semibold)).disabled(model.transferring)}
            }.frame(maxWidth:.infinity).padding(.vertical,24).background(mint.opacity(model.dropActive ? 0.12:0.035),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(mint.opacity(0.3),style:StrokeStyle(lineWidth:1,dash:[6,5])))
            .onDrop(of:[UTType.fileURL.identifier],isTargeted:$model.dropActive) { providers in guard !model.transferring else{return false};loadDroppedURLs(providers){model.add($0)};return true }
            HStack {
                Text(l("ОЧЕРЕДЬ","QUEUE")).font(.system(size:10,weight:.bold,design:.monospaced)).tracking(2).foregroundStyle(muted)
                Text("\(model.jobs.count)").font(.system(size:11,design:.monospaced)).foregroundStyle(muted)
                Spacer()
                Button(l("Убрать переданные","Clear transferred")){model.clearFinished()}.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(muted).disabled(model.busy)
            }
            ScrollView {
                LazyVStack(spacing:7) {
                    if model.jobs.isEmpty {Text(l("Добавьте игры, обновления или DLC","Add games, updates or DLC")).font(.system(size:13)).foregroundStyle(muted).padding(.top,35)}
                    ForEach(model.jobs) {job in jobRow(job)}
                }
            }.frame(minHeight:100)
            Text(l("Установка через SD Card Install. NSZ/XCZ занимают на карте больше места, чем исходный файл.","Installs via SD Card Install. NSZ/XCZ may need more storage space than the source file.")).font(.system(size:11)).foregroundStyle(muted)
        }
    }
    func jobRow(_ job:Job)->some View {
        HStack(spacing:12) {
            Image(systemName:job.state == .sent ? "checkmark.circle.fill":"doc.fill").font(.system(size:20)).foregroundStyle(job.state == .sent ? mint:muted)
            VStack(alignment:.leading,spacing:5) {
                Text(job.name).font(.system(size:12,weight:.medium)).lineLimit(1).truncationMode(.middle).help(job.path)
                Text("\(bytes(job.size)) · \(job.state.title)").font(.system(size:10)).foregroundStyle(job.state == .sent ? mint:muted)
                if job.state == .sending {ProgressView(value:model.progress).tint(mint)}
            }
            Spacer(minLength:0)
            if [.failed,.cancelled,.interrupted].contains(job.state) {Button{model.retry(job.id)}label:{Image(systemName:"arrow.counterclockwise")}.buttonStyle(.plain).help(l("Повторить с начала","Retry from the beginning")).disabled(model.busy)}
            Button{model.remove(job.id)}label:{Image(systemName:"xmark").font(.system(size:10)).foregroundStyle(muted)}.buttonStyle(.plain).help(l("Убрать из очереди","Remove from queue")).disabled(model.busy)
        }.padding(12).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
    }
    var footer: some View {
        VStack(alignment:.leading,spacing:12) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height:1)
            HStack(spacing:15) {
                VStack(alignment:.leading,spacing:6) {
                    Text(browserMessage(translated(model.status))).font(.system(size:12,weight:.medium)).lineLimit(2)
                    if model.transferring {
                        if model.fsActive {Text(model.currentName).font(.system(size:10)).foregroundStyle(muted).lineLimit(1)}
                        Text("\(bytes(model.sent)) / \(bytes(model.currentSize)) · \(bytes(Int64(model.speed)))/\(l("с","s")) · \(model.eta)").font(.system(size:10,design:.monospaced)).foregroundStyle(muted)
                        if model.fsActive {ProgressView(value:model.progress).tint(mint).frame(maxWidth:400)}
                    } else if model.viewMode=="games" {Text(l("В очереди: \(model.pending.count) · \(bytes(model.total))","Queued: \(model.pending.count) · \(bytes(model.total))")).font(.system(size:11)).foregroundStyle(muted)}
                }
                Spacer(minLength:0)
                if model.transferring {
                    Button{model.cancel()}label:{Text(model.stopping ? l("Остановка…","Stopping…"):l("Остановить","Stop")).font(.system(size:13,weight:.semibold)).padding(.horizontal,20).padding(.vertical,12)}.buttonStyle(.plain).background(Color.orange.opacity(0.15),in:RoundedRectangle(cornerRadius:10)).disabled(model.stopping)
                } else if model.viewMode=="games" {
                    Button{model.start()}label:{HStack{Text(l("Передать","Transfer"));Image(systemName:"arrow.right")}.font(.system(size:13,weight:.bold)).foregroundStyle(model.ready ? Color.black:muted).padding(.horizontal,22).padding(.vertical,12)}.buttonStyle(.plain).background(model.ready ? mint:Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:10)).disabled(!model.ready)
                } else if model.busy {ProgressView().controlSize(.small)}
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let store = Store()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMenus()
        NotificationCenter.default.addObserver(self, selector: #selector(configureMenus), name: Notification.Name("LanguageChanged"), object: nil)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SwitchDrop"; window.minSize = NSSize(width: 1000, height: 680)
        window.titlebarAppearsTransparent = true; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ContentView(model: store)); window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.store.scan() }
    }
    @objc func configureMenus() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: l("О SwitchDrop","About SwitchDrop"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: l("Завершить SwitchDrop","Quit SwitchDrop"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let editItem = NSMenuItem(); editItem.title = l("Правка","Edit"); let edit = NSMenu(title: l("Правка","Edit"))
        edit.addItem(withTitle: l("Вырезать","Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: l("Вставить","Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: l("Копировать","Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"); edit.addItem(withTitle: l("Выбрать всё","Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
    }
    func application(_ application: NSApplication, open urls: [URL]) { store.add(urls) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { mayQuit() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { mayQuit() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func mayQuit() -> Bool {
        if store.transferring {
            let a = NSAlert(); a.messageText = l("Идёт передача файлов","A file transfer is in progress")
            a.informativeText = l("Сначала остановите передачу и дождитесь ответа DBI. Окно останется открытым.","Stop the transfer first and wait for DBI to respond. The window will stay open.")
            a.addButton(withTitle: l("Продолжить передачу","Continue transfer")); a.addButton(withTitle: l("Остановить передачу","Stop transfer"))
            if a.runModal() == .alertSecondButtonReturn { store.cancel() }; return false
        }
        if store.busy { store.cancel() }
        store.disconnect()
        return true
    }
}

func selfTest() {
    let originalLanguage=UI.language
    UI.language = .en; precondition(JobState.queued.title == "Queued" && bytes(1000) == "1.0 KB")
    let localizedError=l("Проблема","Problem"); UI.language = .ru
    precondition(translated(localizedError) == "Проблема" && JobState.queued.title == "В очереди")
    UI.language = originalLanguage

    let frame = encodeCommand(["send", "5", "Игра\nNSP.nsp"])
    let payload = frame.dropFirst(4)
    let count = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    precondition(Int(count) == payload.count && payload.last == 0)
    precondition(String(decoding: payload, as: UTF8.self) == "send\05\0Игра\nNSP.nsp\0")
    var decoder = EventDecoder()
    let data = "{\"type\":\"detail\",\"message\":\"Игра 🎮\"}\n{\"type\":\"progress\",\"sent\":8589934599}\n".data(using: .utf8)!
    var events = [[String: Any]]()
    for byte in data { events += decoder.feed(Data([byte])) }
    precondition(events.count == 2 && events[0]["message"] as? String == "Игра 🎮")
    precondition((events[1]["sent"] as? NSNumber)?.int64Value == 8589934599)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Игра.NSP"); try! Data([1, 2, 3]).write(to: file)
    let state = root.appendingPathComponent("queue.json")
    let s = Store(stateURL: state); s.add([file, file]); precondition(s.jobs.count == 1 && s.total == 3)
    s.jobs[0].state = .sending; s.persist()
    let restored = Store(stateURL: state); precondition(restored.jobs[0].state == .interrupted && restored.pending.isEmpty)
    restored.retry(restored.jobs[0].id); precondition(restored.pending.count == 1)
    restored.activeTest()
    print("Swift tests passed: fragmented UTF-8 events, >4 GB counters, queue persistence, interrupted recovery, duplicate filtering, failed session state.")
}
extension Store {
    func activeTest() {
        jobs[0].state = .sending; finished(1, transfer: true)
        precondition(jobs[0].state == .failed && !busy && !problem.isEmpty)
    }
}
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--self-test") { selfTest() }
else {
    let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
