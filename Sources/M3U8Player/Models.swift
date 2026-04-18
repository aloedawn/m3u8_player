import Foundation

struct Channel: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let number: Int
    let category: String
}

// MARK: - JSON 디코딩용 중간 타입

private struct ChannelDTO: Decodable {
    let name: String
    let url: String
    let number: Int
    let category: String
}

// MARK: - 번들에서 Channels.json 로딩

extension Channel {
    /// 번들 내 Channels.json 에서 채널 목록을 읽어 반환합니다.
    /// 파일이 없거나 파싱 실패 시 빈 배열을 반환합니다.
    static func loadFromBundle() -> [Channel] {
        guard let fileURL = Bundle.main.url(forResource: "Channels", withExtension: "json") else {
            print("⚠️  Channels.json 을 번들에서 찾을 수 없습니다. Channels.json.example 을 복사해 작성하세요.")
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let dtos = try JSONDecoder().decode([ChannelDTO].self, from: data)
            return dtos.compactMap { dto in
                guard let url = URL(string: dto.url) else { return nil }
                return Channel(name: dto.name, url: url, number: dto.number, category: dto.category)
            }
            .sorted { $0.number < $1.number }
        } catch {
            print("⚠️  Channels.json 파싱 오류: \(error)")
            return []
        }
    }
}
