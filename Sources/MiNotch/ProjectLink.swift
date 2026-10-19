import Foundation

/// Los enlaces solo seleccionan carpetas existentes; no aceptan prompts ni comandos.
enum ProjectLink {
    static func directory(from url: URL) -> URL? {
        if url.isFileURL { return existingDirectory(url) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "minotch", components.host == "open",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/",
              let items = components.queryItems, items.count == 1,
              items[0].name == "path", let path = items[0].value, path.hasPrefix("/"),
              !path.contains("\0") else { return nil }
        return existingDirectory(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func url(for directory: URL) -> URL {
        var components = URLComponents()
        components.scheme = "minotch"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: directory.path)]
        return components.url!
    }

    private static func existingDirectory(_ url: URL) -> URL? {
        guard url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { return nil }
        var isDirectory: ObjCBool = false
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return normalized
    }
}
