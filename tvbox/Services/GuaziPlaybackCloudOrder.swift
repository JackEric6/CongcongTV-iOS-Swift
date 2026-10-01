import Foundation

struct GuaziPlaybackCloud: Equatable, Sendable {
    let index: Int
    let id: String
    let name: String
}

enum GuaziPlaybackCloudOrder {
    static func ordered(
        _ clouds: [GuaziPlaybackCloud],
        preferredName: String
    ) -> [GuaziPlaybackCloud] {
        let apiOrder = clouds.sorted { $0.index < $1.index }
        guard !preferredName.isEmpty,
              let preferredIndex = apiOrder.firstIndex(where: { $0.name == preferredName }) else {
            return apiOrder
        }

        let preferred = apiOrder[preferredIndex]
        return [preferred] + apiOrder.filter { $0.index != preferred.index }
    }
}
