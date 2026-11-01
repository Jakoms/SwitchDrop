import Cocoa
import SwiftUI
import UniformTypeIdentifiers

let mtpRoot = Int(UInt32.max)
struct RemoteStorage: Identifiable {
    let id: Int, label: String, writable: Bool, install: Bool, free: Int64
}
struct RemoteEntry: Identifiable {
    let id: Int, parent: Int, storage: Int, name: String, folder: Bool, size: Int64
}
struct DeletionPreview {
    let storage: Int, id: Int, token: String, name: String, files: Int, folders: Int, bytes: Int64
}
struct UploadConflict {
    let token: String, path: String, name: String
    let sourceFolder: Bool, destinationFolder: Bool
    let sourceSize: Int64, destinationSize: Int64
    var filePair: Bool { !sourceFolder && !destinationFolder }
    static func decode(_ e: [String:Any]) -> UploadConflict? {
        guard let token=e["token"] as? String, let path=e["path"] as? String, let name=e["name"] as? String else {return nil}
        return UploadConflict(token:token,path:path,name:name,sourceFolder:e["sourceFolder"] as? Bool ?? false,destinationFolder:e["destinationFolder"] as? Bool ?? false,sourceSize:(e["sourceSize"] as? NSNumber)?.int64Value ?? 0,destinationSize:(e["destinationSize"] as? NSNumber)?.int64Value ?? 0)
    }
}
struct RemoteLocation { let id: Int, name: String }

func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup(), lock = NSLock(); var urls = [(Int, URL)]()
    for (index, provider) in providers.enumerated() {
        group.enter()
        provider.loadObject(ofClass: NSURL.self) { value, _ in
            if let url = value as? URL { lock.lock(); urls.append((index,url)); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls.sorted { $0.0 < $1.0 }.map { $0.1 }) }
}

extension Store {
    var browserStorage: RemoteStorage? { remoteStorages.first { $0.id == browserStorageID } }
    var currentFolder: Int { browserPath.last?.id ?? mtpRoot }
    var selectedEntry: RemoteEntry? { entries.first { $0.id == selectedEntryID } }
    var canWrite: Bool { browserStorage?.writable == true && !busy }
    var visibleEntries: [RemoteEntry] {
        entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted {
            if $0.folder != $1.folder { return $0.folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func showFiles() {
        viewMode = "files"
        if browserStorageID == 0 {
            browserStorageID = remoteStorages.first(where: { $0.writable })?.id ?? remoteStorages.first(where: { !$0.install })?.id ?? 0
        }
        if !busy && browserStorageID != 0 { loadFolder() }
    }
    func selectStorage(_ id: Int) {
        guard !busy else { return }
        browserStorageID = id; browserPath = []; selectedEntryID = nil; entries = []; search = ""; loadFolder()
    }
    func loadFolder() {
        guard browserStorageID != 0 else { return }
        selectedEntryID = nil
        requestFS(["list", String(browserStorageID), String(currentFolder)], transfer: false)
    }
    func openFolder(_ entry: RemoteEntry) {
        guard !busy, entry.folder else { return }
        browserPath.append(RemoteLocation(id: entry.id, name: entry.name)); search = ""; loadFolder()
    }
    func goTo(_ depth: Int) {
        guard !busy else { return }
        browserPath = Array(browserPath.prefix(depth)); search = ""; loadFolder()
    }
    func upload(_ urls: [URL], to folder: Int? = nil) {
        guard canWrite, !urls.isEmpty else { return }
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        requestFS(["upload", String(browserStorageID), String(folder ?? currentFolder)] + paths, transfer: true)
    }
    func confirmUploadConflict(_ conflict: UploadConflict) {
        guard transferring, fsActive, activeUploadConflictToken==conflict.token else {return}
        let generation=connectionGeneration
        let alert=NSAlert()
        alert.messageText=l("«\(conflict.name)» уже существует", "“\(conflict.name)” already exists")
        let source=conflict.sourceFolder ? l("папка","folder") : bytes(conflict.sourceSize)
        let destination=conflict.destinationFolder ? l("папка","folder") : bytes(conflict.destinationSize)
        alert.informativeText=l("С Mac: \(source)\nНа Switch: \(destination)\n\n\(conflict.path)\n\nПапки с одинаковым именем объединяются. Существующие файлы требуют выбора.","From Mac: \(source)\nOn Switch: \(destination)\n\n\(conflict.path)\n\nFolders with matching names are merged. Existing files require a choice.")
        var choices=["skip","keep"]
        alert.addButton(withTitle:l("Пропустить","Skip"))
        alert.addButton(withTitle:l("Сохранить оба","Keep both"))
        if conflict.filePair {
            choices.append("replace")
            alert.addButton(withTitle:l("Заменить файл","Replace file")).hasDestructiveAction=true
        }
        choices.append("stop")
        alert.addButton(withTitle:l("Остановить копирование","Stop copying")).keyEquivalent="\u{1b}"
        let apply=NSButton(checkboxWithTitle:l("Применить ко всем конфликтам файлов в этой передаче","Apply to all file conflicts in this transfer"),target:nil,action:nil)
        apply.frame=NSRect(x:0,y:0,width:400,height:24)
        if conflict.filePair {alert.accessoryView=apply}
        let index=alert.runModal().rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard generation==connectionGeneration else {return}
        let choice=choices.indices.contains(index) ? choices[index] : "stop"
        respondUploadConflict(conflict.token,choice:choice,applyToAll:conflict.filePair && apply.state == .on)
    }
    func chooseUpload() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true; p.canChooseFiles = true
        p.prompt = l("Загрузить", "Upload"); p.message = l("Файлы будут скопированы в открытую папку Switch", "Files will be copied into the current Switch folder")
        if p.runModal() == .OK { upload(p.urls) }
    }
    func download(_ entry: RemoteEntry) {
        guard !busy, !entry.folder else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = entry.name; p.prompt = l("Скачать", "Download")
        if p.runModal() == .OK, let url = p.url {
            requestFS(["download",String(entry.storage),String(entry.id),url.path], transfer: true)
        }
    }
    func nameDialog(title: String, value: String, action: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: value); field.frame = NSRect(x:0,y:0,width:330,height:24)
        alert.accessoryView = field; alert.addButton(withTitle: action); alert.addButton(withTitle: l("Отмена","Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    func newFolder() {
        guard canWrite, let name = nameDialog(title: l("Новая папка","New folder"),value: "",action:l("Создать","Create")), !name.isEmpty else { return }
        requestFS(["mkdir",String(browserStorageID),String(currentFolder),name], transfer:false)
    }
    func rename(_ entry: RemoteEntry) {
        guard canWrite, let name = nameDialog(title:l("Переименовать","Rename"),value:entry.name,action:l("Переименовать","Rename")), name != entry.name else { return }
        requestFS(["rename",String(entry.storage),String(entry.id),name], transfer:false)
    }
    func delete(_ entry: RemoteEntry) {
        guard canWrite else { return }
        pendingDeletion = nil
        requestFS(["deleteplan",String(entry.storage),String(entry.id)], transfer:false)
    }
    func confirmDeletion(_ plan: DeletionPreview) {
        guard canWrite else { return }
        let generation=connectionGeneration
        let alert = NSAlert()
        alert.messageText = l("Удалить «\(plan.name)»?", "Delete “\(plan.name)”?")
        alert.informativeText = l(
            "Будут удалены: файлов — \(plan.files), папок — \(plan.folders). Объём файлов: \(bytes(plan.bytes)).\n\nПапка удаляется со всем содержимым, включая вложенные папки. Корзины нет; отменить удаление нельзя.",
            "This will delete \(plan.files) files and \(plan.folders) folders. File size: \(bytes(plan.bytes)).\n\nFolders are deleted with all their contents and subfolders. There is no Trash and no undo.")
        alert.addButton(withTitle:l("Отмена","Cancel"))
        alert.addButton(withTitle:l("Удалить навсегда","Delete permanently")).hasDestructiveAction = true
        let confirmed = alert.runModal() == .alertSecondButtonReturn
        pendingDeletion = nil
        guard generation==connectionGeneration else {return}
        requestFS([confirmed ? "deletecommit" : "deletecancel",String(plan.storage),String(plan.id),plan.token], transfer:confirmed)
    }

}

struct FileBrowserView: View {
    @ObservedObject var model: Store
    @State private var dropActive = false
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Picker(l("Хранилище","Storage"),selection:Binding(get:{model.browserStorageID},set:{model.selectStorage($0)})) {
                    Text(l("Выберите хранилище","Choose storage")).tag(0)
                    ForEach(model.remoteStorages.filter { !$0.install }) { s in Text(s.label).tag(s.id) }
                }.labelsHidden().frame(width:230).disabled(model.busy)
                if let s=model.browserStorage {
                    Text(s.writable ? l("Чтение и запись","Read & write") : l("Только чтение","Read only")).font(.system(size:11)).foregroundStyle(s.writable ? mint : muted)
                }
                Spacer()
                TextField(l("Поиск в папке","Search folder"),text:$model.search).textFieldStyle(.roundedBorder).frame(width:180)
            }
            HStack(spacing:8) {
                Button { model.goTo(max(0,model.browserPath.count-1)) } label:{Image(systemName:"arrow.up")}.disabled(model.busy || model.browserPath.isEmpty)
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:6) {
                        Button("/") { model.goTo(0) }.buttonStyle(.plain).foregroundStyle(mint)
                        ForEach(Array(model.browserPath.enumerated()),id:\.offset) { index, location in
                            Image(systemName:"chevron.right").font(.system(size:8)).foregroundStyle(muted)
                            Button(location.name) { model.goTo(index+1) }.buttonStyle(.plain).font(.system(size:12))
                        }
                    }
                }.disabled(model.busy)
                Button { model.loadFolder() } label:{Image(systemName:"arrow.clockwise")}.help(l("Обновить папку","Refresh folder")).disabled(model.busy || model.browserStorageID==0)
            }
            HStack(spacing:12) {
                Button { model.chooseUpload() } label:{Label(l("Загрузить…","Upload…"),systemImage:"arrow.up.doc")}.disabled(!model.canWrite)
                Button { if let e=model.selectedEntry { model.download(e) } } label:{Label(l("Скачать…","Download…"),systemImage:"arrow.down.doc")}.disabled(model.busy || model.selectedEntry==nil || model.selectedEntry?.folder==true)
                Button { model.newFolder() } label:{Label(l("Новая папка","New folder"),systemImage:"folder.badge.plus")}.disabled(!model.canWrite)
                Spacer()
                Button { if let e=model.selectedEntry {model.rename(e)} } label:{Image(systemName:"pencil")}.help(l("Переименовать","Rename")).disabled(!model.canWrite || model.selectedEntry==nil)
                Button { if let e=model.selectedEntry {model.delete(e)} } label:{Image(systemName:"trash")}.help(l("Удалить","Delete")).disabled(!model.canWrite || model.selectedEntry==nil)
            }.controlSize(.small)
            Table(model.visibleEntries,selection:$model.selectedEntryID) {
                TableColumn(l("Имя","Name")) { e in
                    HStack(spacing:8) {
                        Image(systemName:e.folder ? "folder.fill":"doc").foregroundStyle(e.folder ? mint:muted)
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    .onTapGesture(count:2) { if e.folder {model.openFolder(e)} else {model.download(e)} }
                    .contextMenu {
                        if e.folder {Button(l("Открыть","Open")){model.openFolder(e)}}
                        else {Button(l("Скачать…","Download…")){model.download(e)}}
                        Divider()
                        Button(l("Переименовать…","Rename…")){model.rename(e)}.disabled(!model.canWrite)
                        Button(l("Удалить…","Delete…"),role:.destructive){model.delete(e)}.disabled(!model.canWrite)
                    }
                    .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { providers in
                        guard model.canWrite,e.folder else{return false}
                        loadDroppedURLs(providers){model.upload($0,to:e.id)};return true
                    }
                }.width(min:220,ideal:470)
                TableColumn(l("Размер","Size")) { e in Text(e.folder ? "—":bytes(e.size)).foregroundStyle(muted).monospacedDigit() }.width(85)
                TableColumn(l("Тип","Kind")) { e in Text(e.folder ? l("Папка","Folder"):URL(fileURLWithPath:e.name).pathExtension.uppercased()).foregroundStyle(muted) }.width(75)
            }
            .overlay {
                if model.entries.isEmpty && !model.busy {
                    VStack(spacing:10) {
                        Image(systemName:"folder").font(.system(size:32)).foregroundStyle(muted)
                        Text(model.browserStorageID==0 ? l("Подключите Switch и выберите хранилище","Connect your Switch and choose a storage"):l("Папка пуста","This folder is empty")).font(.system(size:13)).foregroundStyle(muted)
                    }.allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius:10).stroke(mint.opacity(dropActive ? 0.8:0),lineWidth:2))
            .onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropActive) { providers in
                guard model.canWrite else{return false}
                loadDroppedURLs(providers){model.upload($0)};return true
            }
            HStack {
                Text(l("\(model.visibleEntries.count) объектов","\(model.visibleEntries.count) items")).font(.system(size:11)).foregroundStyle(muted)
                Spacer()
                Text(model.canWrite ? l("Перетащите сюда файлы или папки из Finder","Drop files or folders here from Finder"):l("Изменение файлов доступно на SD Card","File changes are available on SD Card")).font(.system(size:11)).foregroundStyle(muted)
            }
            Text(l("Здесь файлы копируются на карту. Для установки игр используйте вкладку «Установка игр».","This browser copies files to storage. Use the Install games tab to install game packages.")).font(.system(size:11)).foregroundStyle(muted)
        }
    }
}
