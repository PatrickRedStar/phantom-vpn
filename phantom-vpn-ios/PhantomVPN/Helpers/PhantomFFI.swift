import Foundation

@_silgen_name("phantom_start")
func phantom_start(_ tun_fd: Int32, _ config_json: UnsafePointer<CChar>) -> Int32

@_silgen_name("phantom_stop")
func phantom_stop()

@_silgen_name("phantom_get_stats")
func phantom_get_stats() -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_get_logs")
func phantom_get_logs(_ since_seq: Int64) -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_set_log_level")
func phantom_set_log_level(_ level: UnsafePointer<CChar>)

@_silgen_name("phantom_compute_vpn_routes")
func phantom_compute_vpn_routes(_ direct_cidrs: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_free_string")
func phantom_free_string(_ ptr: UnsafeMutablePointer<CChar>)
