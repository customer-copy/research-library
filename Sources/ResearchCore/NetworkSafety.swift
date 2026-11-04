import Darwin
import Foundation

/// Decides whether a host is on the public internet. Captured links come from web pages,
/// so the app must never be steered into fetching loopback, LAN or link-local addresses.
public enum NetworkSafety {
  /// True for IP literals in non-public ranges, malformed IPv6 literals, and non-canonical
  /// numeric forms that resolvers interpret as IPv4 (e.g. "127.1", "0x7f.0.0.1",
  /// "2130706433"). Ordinary domain names return false here; see `resolvesToNonPublicAddress`.
  public static func isBlockedLiteral(_ rawHost: String) -> Bool {
    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host.contains(":") {
      var address = in6_addr()
      guard inet_pton(AF_INET6, host, &address) == 1 else { return true }
      return isNonPublic(ipv6: withUnsafeBytes(of: &address) { Array($0) })
    }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let numericLabel: (String) -> Bool = { label in
      !label.isEmpty && (label.allSatisfy(\.isASCII) && label.allSatisfy(\.isNumber)
        || (label.hasPrefix("0x") && label.dropFirst(2).allSatisfy(\.isHexDigit)))
    }
    guard labels.allSatisfy(numericLabel) else { return false }  // a domain name
    // Only canonical dotted-quad decimal is accepted, and only for public ranges.
    guard labels.count == 4,
      labels.allSatisfy({ !$0.hasPrefix("0x") && ($0 == "0" || !$0.hasPrefix("0")) })
    else { return true }
    let octets = labels.compactMap { UInt8($0) }
    guard octets.count == 4 else { return true }
    return isNonPublic(ipv4: octets)
  }

  public static func isNonPublic(ipv4 o: [UInt8]) -> Bool {
    guard o.count == 4 else { return true }
    switch (o[0], o[1]) {
    case (0, _), (10, _), (127, _): return true
    case (100, 64...127): return true  // carrier-grade NAT
    case (169, 254): return true  // link-local
    case (172, 16...31): return true
    case (192, 168): return true
    case (192, 0) where o[2] == 0: return true  // IETF protocol assignments
    case (198, 18...19): return true  // benchmarking
    case (224...255, _): return true  // multicast, reserved, broadcast
    default: return false
    }
  }

  public static func isNonPublic(ipv6 b: [UInt8]) -> Bool {
    guard b.count == 16 else { return true }
    if b.allSatisfy({ $0 == 0 }) { return true }  // ::
    if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }  // ::1
    if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
    if (b[0] & 0xfe) == 0xfc { return true }  // fc00::/7 unique local
    if b[0] == 0xff { return true }  // multicast
    if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 { return true }  // deprecated site-local
    // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d) and NAT64 (64:ff9b::/96).
    let mapped = b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff
    let compatible = b[0..<12].allSatisfy({ $0 == 0 })
    let nat64 = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy({ $0 == 0 })
    if mapped || compatible || nat64 { return isNonPublic(ipv4: Array(b[12..<16])) }
    return false
  }

  /// Resolves `host` and returns true if any address is non-public (for example a public
  /// name pointed at 127.0.0.1 or a LAN address). Resolution failures return false; the
  /// request then fails normally.
  public static func resolvesToNonPublicAddress(_ rawHost: String) -> Bool {
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if isBlockedLiteral(host) { return true }
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
    defer { freeaddrinfo(first) }
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let entry = cursor {
      if let address = entry.pointee.ai_addr {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
          let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
          }
          if isNonPublic(ipv4: bytes) { return true }
        case AF_INET6:
          let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
          }
          if isNonPublic(ipv6: bytes) { return true }
        default: break
        }
      }
      cursor = entry.pointee.ai_next
    }
    return false
  }
}
