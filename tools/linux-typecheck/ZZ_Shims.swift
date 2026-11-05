import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// Linux-only stand-ins for Apple frameworks, used by the typecheck harness. Never shipped.
struct SHA256Digest: Sequence { func makeIterator() -> IndexingIterator<[UInt8]> { [UInt8]().makeIterator() }; var description: String { "" } }
enum SHA256 { static func hash<D: DataProtocol>(data: D) -> SHA256Digest { SHA256Digest() } }
// Contacts
class CNLabeledValue<T> { let value: T; init(_ v: T) { value = v } }
class CNPhoneNumber { var stringValue: String = "" }
class CNContact { var givenName = ""; var familyName = ""; var phoneNumbers: [CNLabeledValue<CNPhoneNumber>] = []; var emailAddresses: [CNLabeledValue<NSString>] = []; var organizationName = ""
  static func authorizationStatus(for: CNEntityType) -> CNAuthorizationStatus { .denied } }
let CNContactGivenNameKey = "g", CNContactFamilyNameKey = "f", CNContactPhoneNumbersKey = "p", CNContactEmailAddressesKey = "e", CNContactOrganizationNameKey = "o"
protocol CNKeyDescriptor {}
extension String: CNKeyDescriptor {}
extension NSString: CNKeyDescriptor {}
class CNContactFetchRequest { init(keysToFetch: [CNKeyDescriptor]) {} }
enum CNEntityType { case contacts }
enum CNAuthorizationStatus { case authorized, denied, notDetermined, restricted, limited }
class CNContactStore { init() {}
  func enumerateContacts(with: CNContactFetchRequest, usingBlock: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void) throws {}
  func requestAccess(for: CNEntityType, completionHandler: @escaping (Bool, Error?) -> Void) {}
  func requestAccess(for: CNEntityType) async throws -> Bool { false } }
// SignalReader (Mac keychain + CommonCrypto) stand-in
class SignalReader { init(dbPath: String) {}
  func connect() throws {}; func disconnect() {}
  func fetchMessages(since: Date) throws -> [Message] { [] }
  func fetchThreads(since: Date) throws -> [MessageThread] { [] } }
// Combine / SwiftUI
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<V> { var wrappedValue: V; init(wrappedValue: V) { self.wrappedValue = wrappedValue } }
class MenuBarController { init() {}; func setup() {}
  func postNotification(title: String, body: String) {}
  func notifyCadenceResult(_ name: String, success: Bool, summary: String) {} }
#if canImport(Glibc)
import Glibc
enum Darwin {
  static func socket(_ a: Int32, _ b: __socket_type, _ c: Int32) -> Int32 { Glibc.socket(a, Int32(b.rawValue), c) }
  static func bind(_ a: Int32, _ b: UnsafePointer<sockaddr>!, _ c: socklen_t) -> Int32 { Glibc.bind(a, b, c) }
  static func close(_ a: Int32) -> Int32 { Glibc.close(a) }
  static func listen(_ a: Int32, _ b: Int32) -> Int32 { Glibc.listen(a, b) }
  static func accept(_ a: Int32, _ b: UnsafeMutablePointer<sockaddr>!, _ c: UnsafeMutablePointer<socklen_t>!) -> Int32 { Glibc.accept(a, b, c) }
  static func send(_ a: Int32, _ b: UnsafeRawPointer!, _ c: Int, _ d: Int32) -> Int { Glibc.send(a, b, c, d) }
}
#endif
class RelativeDateTimeFormatter { enum Style { case full, short, abbreviated }; var unitsStyle: Style = .full; init() {}
  func localizedString(for: Date, relativeTo: Date) -> String { "" } }
class NSWorkspace { static let shared = NSWorkspace(); func open(_ u: URL) -> Bool { true } }
extension CNContactStore { static func authorizationStatus(for: CNEntityType) -> CNAuthorizationStatus { .denied } }
enum UNAuthorizationStatus { case authorized, provisional, ephemeral, denied, notDetermined }
class UNNotificationSettings { var authorizationStatus: UNAuthorizationStatus = .denied }
class UNUserNotificationCenter { static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
  func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void) {} }
struct _AsyncLines: AsyncSequence { typealias Element = String
  struct AsyncIterator: AsyncIteratorProtocol { mutating func next() async throws -> String? { nil } }
  func makeAsyncIterator() -> AsyncIterator { AsyncIterator() } }
struct _AsyncBytes: AsyncSequence { typealias Element = UInt8
  struct AsyncIterator: AsyncIteratorProtocol { mutating func next() async throws -> UInt8? { nil } }
  func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
  var lines: _AsyncLines { _AsyncLines() } }
extension URLSession { func bytes(for r: URLRequest) async throws -> (_AsyncBytes, URLResponse) { (_AsyncBytes(), URLResponse(url: URL(string: "http://x")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)) } }
#if canImport(Glibc)
extension Darwin { static func signal(_ s: Int32, _ h: @escaping @convention(c) (Int32) -> Void) -> Void { _ = Glibc.signal(s, h) }
  static func signal(_ s: Int32, _ h: __sighandler_t?) -> Void { _ = Glibc.signal(s, h) } }
#endif
struct UNAuthorizationOptions: OptionSet { let rawValue: Int; static let alert = Self(rawValue: 1), sound = Self(rawValue: 2), badge = Self(rawValue: 4) }
extension UNUserNotificationCenter { func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {} }
enum NSApplicationActivationPolicy { case accessory, regular, prohibited }
class NSApplication { static let shared = NSApplication(); func setActivationPolicy(_ p: NSApplicationActivationPolicy) -> Bool { true }; func run() {} }
enum AlfredApp { static let version = "0" }
