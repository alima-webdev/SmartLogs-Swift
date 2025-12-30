import Foundation

func getPreciseTime() -> UInt64 {
     return DispatchTime.now().uptimeNanoseconds
}
