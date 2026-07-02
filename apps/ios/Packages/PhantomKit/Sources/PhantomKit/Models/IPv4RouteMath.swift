import Foundation

/// Чистая арифметика IPv4-маршрутов, вынесенная из
/// `UpstreamVpnRouteDetector` (macOS app) для тестируемости. Парсинг
/// route-table (sockaddr/sysctl) остаётся в детекторе — сюда вынесены
/// только bit-twiddling-куски, где легче всего допустить регрессию.
public enum IPv4RouteMath {

    /// Длина префикса из 4 байт сетевой маски (network byte order).
    /// Маска ДОЛЖНА быть contiguous (единицы слева, нули справа) —
    /// «дырявая» маска (напр. 255.0.255.0) невалидна и даёт `nil`.
    ///
    /// Массив короче 4 дополняется нулями справа (`255.255` от
    /// route-table = /16).
    public static func prefixLength(fromMaskBytes rawBytes: [UInt8]) -> Int? {
        var bytes = Array(rawBytes.prefix(4))
        while bytes.count < 4 { bytes.append(0) }

        var prefix = 0
        var foundZero = false
        for byte in bytes {
            for bit in (0..<8).reversed() {
                let isOne = (byte & UInt8(1 << bit)) != 0
                if isOne {
                    guard !foundZero else { return nil }
                    prefix += 1
                } else {
                    foundZero = true
                }
            }
        }
        return prefix
    }

    /// Компаратор для стабильной сортировки CIDR: по октетам, затем по
    /// префиксу. Используется, чтобы `routeHash`/диагностика были
    /// детерминированны независимо от порядка обхода route-table.
    public static func cidrSortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        func parts(_ cidr: String) -> ([Int], Int) {
            let split = cidr.split(separator: "/")
            let octets = split.first?
                .split(separator: ".")
                .compactMap { Int($0) } ?? []
            let prefix = split.count > 1 ? Int(split[1]) ?? 0 : 0
            return (octets, prefix)
        }
        let left = parts(lhs)
        let right = parts(rhs)
        return left.0 == right.0 ? left.1 < right.1 : left.0.lexicographicallyPrecedes(right.0)
    }
}
