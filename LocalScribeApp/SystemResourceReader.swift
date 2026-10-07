import Darwin
import LocalScribeCore

/// Public Mach host APIs only; permission/error results stay unavailable.
enum SystemResourceReader {
    static func cpuTicks() -> [SystemCPUTicks]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count)
        defer {
            if let info {
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                              vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
            }
        }
        guard result == KERN_SUCCESS, let info, cores > 0,
              UInt64(count) >= UInt64(cores) * UInt64(CPU_STATE_MAX) else { return nil }
        return (0..<Int(cores)).map { core in
            let start = core * Int(CPU_STATE_MAX)
            return SystemCPUTicks(user: UInt32(bitPattern: info[start + Int(CPU_STATE_USER)]),
                                  system: UInt32(bitPattern: info[start + Int(CPU_STATE_SYSTEM)]),
                                  idle: UInt32(bitPattern: info[start + Int(CPU_STATE_IDLE)]),
                                  nice: UInt32(bitPattern: info[start + Int(CPU_STATE_NICE)]))
        }
    }

    static func memory() -> SystemMemorySnapshot? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let required = MemoryLayout<vm_statistics64_data_t>.offset(of: \.compressor_page_count)! + MemoryLayout<UInt32>.size
        guard result == KERN_SUCCESS, Int(count) * MemoryLayout<integer_t>.size >= required else { return nil }
        let size = UInt64(pageSize)
        return SystemMemorySnapshot(pageSizeBytes: size, freeBytes: UInt64(info.free_count) * size,
                                    activeBytes: UInt64(info.active_count) * size,
                                    inactiveBytes: UInt64(info.inactive_count) * size,
                                    wiredBytes: UInt64(info.wire_count) * size,
                                    compressedBytes: UInt64(info.compressor_page_count) * size,
                                    purgeableBytes: UInt64(info.purgeable_count) * size,
                                    speculativeBytes: UInt64(info.speculative_count) * size)
    }
}
