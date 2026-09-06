// Проверка обновлений — с двух площадок.
//
// В репозитории лежит манифест update.json: номер свежей версии и ссылки
// на скачивание. Приложение спрашивает источники ПО ОЧЕРЕДИ — сначала
// GitFlic (доступен из России без VPN), потом GitHub. Кто ответил — тот
// и источник: его ссылка на скачивание пробуется первой, остальные —
// запасные. Если манифест недоступен нигде (старые выпуски без него) —
// откат на GitHub API, как было раньше.
// В сеть уходят только запросы номера версии, без данных о пользователе.

import Foundation

let RELEASES_PAGE = "https://github.com/moznoazachem/giga-pisar/releases/latest"
private let LATEST_API = "https://api.github.com/repos/moznoazachem/giga-pisar/releases/latest"

/// Манифесты по площадкам, в порядке опроса.
private let MANIFESTS = [
    "https://gitflic.ru/project/moznoazachem/giga/blob/raw?file=update.json&branch=main",
    "https://raw.githubusercontent.com/moznoazachem/giga-pisar/main/update.json",
]

/// Свежий выпуск: номер версии и ссылки на zip в порядке предпочтения.
struct UpdateInfo {
    let version: String
    let downloads: [URL]
    /// Что нового в этой версии, по строкам (из манифеста; может быть пусто).
    var notes: [String] = []
}

/// Спрашивает площадки по очереди; nil — не дозвонились ни до одной.
func fetchLatestRelease(_ done: @escaping (UpdateInfo?) -> Void) {
    tryManifest(0, done)
}

private func tryManifest(_ i: Int, _ done: @escaping (UpdateInfo?) -> Void) {
    guard i < MANIFESTS.count else {
        fetchFromGithubAPI(done) // манифестов нет — старый путь
        return
    }
    guard let url = URL(string: MANIFESTS[i]) else { tryManifest(i + 1, done); return }
    var req = URLRequest(url: url)
    req.timeoutInterval = 8
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        guard let data,
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let list = json["downloads"] as? [String]
        else {
            tryManifest(i + 1, done)
            return
        }
        var urls = list.compactMap { URL(string: $0) }
        // ответившая площадка надёжнее для этого пользователя —
        // её ссылку ставим первой (сравниваем оба элемента честно:
        // компаратор, глядящий только на левый, ломает сортировке инварианты)
        if let host = url.host {
            urls.sort { ($0.host == host ? 0 : 1) < ($1.host == host ? 0 : 1) }
        }
        done(UpdateInfo(version: version, downloads: urls, notes: parseNotes(json["notes"])))
    }.resume()
}

/// Запасной путь для переходного периода: GitHub API, как в 2.5–2.7.
private func fetchFromGithubAPI(_ done: @escaping (UpdateInfo?) -> Void) {
    guard let url = URL(string: LATEST_API) else { done(nil); return }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { done(nil); return }
        let zip = (json["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        done(UpdateInfo(version: v, downloads: zip.map { [$0] } ?? []))
    }.resume()
}

/// Сравнение номеров по частям: «2.10» новее «2.9».
func isNewerVersion(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}
