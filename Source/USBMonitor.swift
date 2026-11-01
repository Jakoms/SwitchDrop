import Foundation
import IOKit

struct USBIdentity: Hashable {
    let registryID: UInt64
    let product: Int
    let bus: Int
    let address: Int
    var isMTP: Bool { product == 0x201d || product == 0x2061 }
    func matches(_ device: Device) -> Bool {
        product == device.product && bus == device.bus && address == device.dev
    }
}

// Read IORegistry only: monitoring never claims or resets a USB interface.
final class USBMonitor {
    private var timer: DispatchSourceTimer?
    init(changed: @escaping ([USBIdentity]) -> Void) {
        let timer=DispatchSource.makeTimerSource(queue:.main)
        timer.schedule(deadline:.now(),repeating:1.0)
        timer.setEventHandler { if let devices=Self.snapshot() { changed(devices) } }
        timer.resume();self.timer=timer
    }
    deinit { timer?.cancel() }
    static func snapshot() -> [USBIdentity]? {
        var iterator: io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator)==KERN_SUCCESS else {return nil}
        defer {IOObjectRelease(iterator)}
        var devices=[USBIdentity]()
        while true {
            let service=IOIteratorNext(iterator)
            if service==0 {break}
            defer {IOObjectRelease(service)}
            var properties:Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service,&properties,kCFAllocatorDefault,0)==KERN_SUCCESS,
                  let values=properties?.takeRetainedValue() as? [String:Any],
                  (values["idVendor"] as? NSNumber)?.intValue==0x057e,
                  let product=(values["idProduct"] as? NSNumber)?.intValue,
                  let address=(values["USB Address"] as? NSNumber)?.intValue,
                  let location=(values["locationID"] as? NSNumber)?.uint32Value else {continue}
            var registryID:UInt64=0
            guard IORegistryEntryGetRegistryEntryID(service,&registryID)==KERN_SUCCESS else {continue}
            devices.append(USBIdentity(registryID:registryID,product:product,bus:Int(location>>24),address:address))
        }
        return devices
    }
}
