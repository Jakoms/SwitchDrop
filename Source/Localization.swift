import Foundation

enum Language: String, CaseIterable { case ru, en }
enum UI {
    static var pairs: [String: (String,String)] = [:]
    static var language = Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "ru") ?? .ru
}
func l(_ ru: String, _ en: String) -> String {
    UI.pairs[ru] = (ru,en); UI.pairs[en] = (ru,en)
    return UI.language == .ru ? ru : en
}
// Backend messages are stored verbatim; translate them when displaying them.
func translated(_ text: String) -> String {
    if let pair=UI.pairs[text] { return UI.language == .ru ? pair.0 : pair.1 }
    guard UI.language == .en else { return text }
    let dictionary: [String: String] = [
        "Подключите Switch и запустите MTP в DBI": "Connect your Switch and start MTP in DBI",
        "Switch подключён · MTP-сессия открыта": "Switch connected · MTP session open",
        "Ищу Switch…": "Looking for your Switch…",
        "Начинаю передачу в открытой MTP-сессии…": "Starting transfer in the open MTP session…",
        "DBI завершает обработку файла…": "DBI is finalizing the file…",
        "Останавливаю… Дождитесь ответа DBI": "Stopping… Waiting for DBI",
        "Передача завершена. Проверьте результат установки на экране DBI.": "Transfer complete. Check the installation result on the DBI screen.",
        "Передача остановлена. Проверьте результат текущей установки в DBI.": "Transfer stopped. Check the current installation in DBI.",
        "Передача остановлена": "Transfer stopped",
        "Подключение не готово": "Not connected",
        "MTP-сессия закрыта": "MTP session closed",
        "Операция остановлена. Уже выполненные изменения сохранены.": "Operation stopped. Changes already made are preserved.",
        "Switch с «SD Card install» не найден. В DBI запустите MTP Responder, подключите USB-кабель и закройте OpenMTP / Android File Transfer.": "Switch not found. Start MTP Responder in DBI, connect a USB data cable and quit OpenMTP / Android File Transfer.",
        "Не удалось получить список MTP-устройств. Закройте OpenMTP и подключите Switch заново.": "Could not list MTP devices. Quit OpenMTP and reconnect your Switch.",
        "DBI не подтвердил передачу. Проверьте экран Switch. Очередь остановлена.": "DBI did not confirm the transfer. Check the Switch screen. The queue has stopped.",
        "Switch найден, но занят или не отвечает. Закройте другие MTP-клиенты.": "Switch found, but busy or not responding. Quit other MTP clients.",
        "Файл недоступен, пуст или имеет неподдерживаемый формат. Очередь остановлена.": "A file is unavailable, empty or unsupported. The queue has stopped.",
        "Устройство изменилось. Обновите подключение.": "The device changed. Reconnect your Switch.",
        "Выбрано неверное установочное хранилище": "Invalid installation storage selected",
        "Switch подключён · установка на SD": "Switch connected · SD installation",
        "Folder loaded": "Folder loaded", "File operation complete": "File operation complete"
    ]
    if let match = dictionary[text] { return match }
    if text.hasPrefix("Передача ") && text.contains(" из ") { return text.replacingOccurrences(of: "Передача ", with: "Transfer ").replacingOccurrences(of: " из ", with: " of ") }
    return text
}
func browserMessage(_ text: String) -> String {
    guard UI.language == .ru else { return text }
    let messages = [
        "Folder loaded": "Папка открыта", "File operation complete": "Операция завершена",
        "This storage is read-only in SwitchDrop. File changes are available on SD Card only.": "Это хранилище доступно только для чтения. Изменение файлов разрешено на SD Card.",
        "An item with this name already exists. Rename it first.": "Файл или папка с таким именем уже существует. Сначала переименуйте его.",
        "The name contains characters unsupported by the SD card.": "В имени есть символы, которые не поддерживает SD-карта.",
        "Only regular files and folders can be uploaded; symbolic links are skipped.": "Можно загружать обычные файлы и папки. Символические ссылки не поддерживаются.",
        "Could not check the destination folder.": "Не удалось проверить папку назначения.",
        "Cannot read the local folder.": "Не удалось прочитать папку на Mac.",
        "Could not create the destination folder.": "Не удалось создать папку на Switch.",
        "Cannot read the local file.": "Не удалось прочитать файл на Mac.",
        "Upload failed. A partial item may remain on the Switch.": "Загрузка не завершена. На Switch мог остаться неполный файл.",
        "Select a file to download.": "Выберите файл для скачивания.",
        "Cannot create the local file. Choose another location.": "Не удалось создать файл на Mac. Выберите другую папку.",
        "Download failed or the destination already exists. Existing files were not changed.": "Скачивание не завершено или файл назначения уже существует. Существующие файлы не изменены.",
        "The destination folder is no longer available.": "Папка назначения больше недоступна.",
        "Could not read this folder.": "Не удалось прочитать папку.",
        "Invalid folder or name.": "Неверная папка или имя.",
        "An item with this name already exists or the folder cannot be read.": "Такое имя уже занято или папку не удалось прочитать.",
        "Could not create the folder.": "Не удалось создать папку.",
        "The selected item is no longer available.": "Выбранный объект больше недоступен.",
        "Invalid name, duplicate name, or the folder cannot be read.": "Недопустимое или занятое имя, либо папка недоступна.",
        "Rename failed.": "Не удалось переименовать.",
        "Delete failed.": "Не удалось удалить.",
        "Only empty folders can be deleted. Remove their contents explicitly first.": "Можно удалять только пустые папки. Сначала удалите их содержимое.",
        "This storage is not browsable. Use the install queue instead.": "Это хранилище предназначено для установки. Используйте очередь игр.",
        "The folder is too large or too deeply nested to delete safely.": "Папка слишком большая или содержит слишком много уровней вложенности.",
        "Deletion stopped: invalid item or storage.": "Удаление остановлено: неверный объект или хранилище.",
        "Deletion stopped: the folder contains repeated object handles.": "Удаление остановлено: обнаружены повторяющиеся идентификаторы объектов.",
        "Could not inspect the folder. Nothing was deleted.": "Не удалось прочитать содержимое папки. Ничего не удалено.",
        "Deletion stopped: invalid parent folder.": "Удаление остановлено: неверная родительская папка.",
        "Could not prepare deletion. Nothing was deleted.": "Не удалось подготовить удаление. Ничего не удалено.",
        "Deletion confirmation expired. Select the item again.": "Подтверждение устарело. Выберите объект ещё раз.",
        "Folder contents changed. Review deletion again. Nothing was deleted.": "Содержимое папки изменилось. Подтвердите удаление заново. Ничего не удалено.",
        "Deletion stopped because an item changed. Some items may already have been deleted.": "Объект изменился. Удаление остановлено; часть объектов уже могла быть удалена.",
        "Deletion stopped because a folder changed. Some items may already have been deleted.": "Папка изменилась. Удаление остановлено; часть объектов уже могла быть удалена.",
        "Deletion failed. Some items may already have been deleted.": "Удаление не завершено; часть объектов уже могла быть удалена.",
        "Операция остановлена. Уже выполненные изменения сохранены.": "Операция остановлена. Уже выполненные изменения сохранены.",
        "Folder nesting is too deep.": "Слишком большая вложенность папок."
    ]
    return messages[text] ?? text
}
