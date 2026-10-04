#if AGENTIC_DEBUGGING
import Foundation
import MachO

/// Which build of the app is running, so the Mac can tell which chat built it: the linker
/// gives every build of a binary its own UUID. No build setting or file in the app is needed.
enum BuildIdentity {
    /// The project file that attached the kit, filled in by the compiler at the call site, so
    /// the Mac knows which folder a build it didn't see came from.
    nonisolated(unsafe) static var sourceFile: String?

    /// The UUIDs of the binary holding the kit's code, which in a Debug build is the app's
    /// debug dylib, and of the app's executable.
    static func ids() -> [String] {
        var ids: [String] = []
        for image in [#dsohandle, _dyld_get_image_header(0).map(UnsafeRawPointer.init)].compactMap({ $0 }) {
            if let id = uuid(of: image), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// The UUID of a 64-bit Mach-O image loaded in memory.
    static func uuid(of image: UnsafeRawPointer) -> String? {
        let header = image.load(as: mach_header_64.self)
        guard header.magic == MH_MAGIC_64 else { return nil }
        var command = image.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
#endif
