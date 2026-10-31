// Two "devices" sharing one folder. Run: swiftc Margin/Sync.swift checks/sync/main.swift -o /tmp/sync-check && /tmp/sync-check
import Foundation

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("margin-sync-\(UUID().uuidString)")
let remote = base.appendingPathComponent("remote")
let ipad = base.appendingPathComponent("ipad"), other = base.appendingPathComponent("other")
for dir in [remote, ipad, other] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
defer { try? fm.removeItem(at: base) }

var ipadStamps: [String: Double] = [:], otherStamps: [String: Double] = [:]

func write(_ device: URL, _ id: String, at time: Double, title: String = "Note", deleted: Double? = nil, drawing: String = "ink") {
    let dir = device.appendingPathComponent(id)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var json: [String: Any] = ["id": id, "title": title, "updatedAt": time]
    if let deleted { json["deletedAt"] = deleted }
    try! JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("note.json"))
    try! Data(drawing.utf8).write(to: dir.appendingPathComponent("drawing.data"))
}
func title(_ device: URL, _ id: String) -> String? {
    (try? Data(contentsOf: device.appendingPathComponent(id).appendingPathComponent("note.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["title"] as? String
}
func drawing(_ device: URL, _ id: String) -> String? {
    (try? Data(contentsOf: device.appendingPathComponent(id).appendingPathComponent("drawing.data"))).map { String(decoding: $0, as: UTF8.self) }
}
func syncIPad(open: Set<String> = [], deleted: Set<String> = []) -> Sync.Outcome {
    try! Sync.reconcile(notes: ipad, remote: remote, stamps: &ipadStamps, open: open, deleted: deleted)
}
func syncOther(open: Set<String> = [], deleted: Set<String> = []) -> Sync.Outcome {
    try! Sync.reconcile(notes: other, remote: remote, stamps: &otherStamps, open: open, deleted: deleted)
}
func count(_ device: URL) -> Int { try! fm.contentsOfDirectory(atPath: device.path).count }

let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString, d = UUID().uuidString

// A new note travels to the other device.
write(ipad, a, at: 1, title: "first")
assert(syncIPad().uploaded == 1)
assert(syncOther().downloaded == 1)
assert(title(other, a) == "first" && drawing(other, a) == "ink")

// A book's search text travels beside the note, and the device's own cache of its pages doesn't.
let extras = ipad.appendingPathComponent(a)
try! Data("book text".utf8).write(to: extras.appendingPathComponent("search.txt"))
try! Data("{}".utf8).write(to: extras.appendingPathComponent("page-text.json"))
write(ipad, a, at: 1.5, title: "first")
assert(syncIPad().uploaded == 1)
assert(syncOther().downloaded == 1)
assert(fm.fileExists(atPath: other.appendingPathComponent(a).appendingPathComponent("search.txt").path))
assert(!fm.fileExists(atPath: other.appendingPathComponent(a).appendingPathComponent("page-text.json").path))

// Nothing to do when nothing changed.
let idle = syncIPad()
assert(idle.uploaded == 0 && idle.downloaded == 0)

// An edit travels back, and its ink comes with it.
write(other, a, at: 2, title: "edited", drawing: "more ink")
_ = syncOther()
assert(syncIPad().downloaded == 1)
assert(title(ipad, a) == "edited" && drawing(ipad, a) == "more ink")

// A note open here isn't overwritten underneath the editor.
write(other, a, at: 3, title: "while open")
_ = syncOther()
assert(syncIPad(open: [a]).downloaded == 0 && title(ipad, a) == "edited")
_ = syncIPad()
assert(title(ipad, a) == "while open")

// Both sides changed: both versions survive.
write(ipad, a, at: 4, title: "here")
write(other, a, at: 5, title: "there")
_ = syncOther()
_ = syncIPad()
assert(title(ipad, a) == "here")
let copies = try! fm.contentsOfDirectory(atPath: ipad.path).filter { $0 != a }
assert(copies.count == 1 && title(ipad, copies[0]) == "there (from another device)")
_ = syncOther()
assert(title(other, a) == "here")

// A file missing from the shared folder never deletes the note here: it uploads again.
write(ipad, b, at: 1)
_ = syncIPad()
try! fm.removeItem(at: remote.appendingPathComponent(b))
assert(syncIPad().uploaded == 1 && title(ipad, b) == "Note")

// Deleting forever follows a note that's in the trash on the other device.
write(ipad, c, at: 1, title: "to delete")
_ = syncIPad()
_ = syncOther()
write(other, c, at: 2, title: "to delete", deleted: 2)
_ = syncOther()
_ = syncIPad()
assert(title(ipad, c) == "to delete")
try! fm.removeItem(at: other.appendingPathComponent(c))
_ = syncOther(deleted: [c])
assert(syncIPad().removed == 1 && title(ipad, c) == nil)
_ = syncOther()
assert(title(other, c) == nil)

// But a note that's still live stays, and comes back for everyone.
write(ipad, d, at: 1, title: "keep me")
_ = syncIPad()
_ = syncOther()
try! fm.removeItem(at: other.appendingPathComponent(d))
_ = syncOther(deleted: [d])
assert(syncIPad().removed == 0 && title(ipad, d) == "keep me")
_ = syncOther()
assert(title(other, d) == "keep me")

// Version history and the AI's cache stay on their own device.
let versions = ipad.appendingPathComponent(a).appendingPathComponent("versions")
try! fm.createDirectory(at: versions, withIntermediateDirectories: true)
try! Data("old".utf8).write(to: versions.appendingPathComponent("v1"))
write(ipad, a, at: 9, title: "with history")
_ = syncIPad()
assert(!fm.fileExists(atPath: remote.appendingPathComponent(a).appendingPathComponent("versions").path))
assert(fm.fileExists(atPath: versions.appendingPathComponent("v1").path))

print("ok")
