import Foundation

func connectionSelfTest(_ helper: URL) {
    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["SWITCHDROP_TEST_ROOT"]!)
    let a=USBIdentity(registryID:100,product:0x201d,bus:42,address:7)
    var devices=[a]
    func configure(_ device:USBIdentity,hang:Bool=false) {
        let value:[String:Any] = ["device":["bus":device.bus,"address":device.address,"product":device.product],"hangPing":hang]
        try! JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("device.json"),options:.atomic)
    }
    func trace(_ name:String)->Int {
        guard let text=try? String(contentsOf:root.appendingPathComponent("trace.jsonl")) else{return 0}
        return text.split(separator:"\n").filter { line in
            let value=(try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any]
            return value?["event"] as? String==name
        }.count
    }
    func spin(_ label:String,timeout:Double=6,until predicate:()->Bool) {
        let end=Date().addingTimeInterval(timeout)
        while !predicate() && Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        precondition(predicate(),"Connection test timed out: \(label)")
    }
    configure(a)
    let store=Store(stateURL:root.appendingPathComponent("queue.json"))
    store.viewMode="games";store.helperOverride=helper;store.usbSnapshot={devices}
    store.scan();spin("first connection"){store.device?.dev==7 && !store.busy}
    precondition(trace("launch")==1)
    store.scan();spin("healthy ping"){!store.busy};precondition(trace("launch")==1)
    let oldGeneration=store.connectionGeneration
    devices=[];store.observeUSB([])
    precondition(store.device==nil && store.remoteStorages.isEmpty && store.pendingDeletion==nil)
    let b=USBIdentity(registryID:101,product:0x201d,bus:42,address:7)
    configure(b);devices=[b];store.observeUSB(devices)
    spin("replug at reused address"){store.device?.dev==7 && !store.busy && trace("launch")==2}
    precondition(store.connectionGeneration != oldGeneration && !store.logs.contains(where:{$0.contains("STALE-EVENT")}))
    let c=USBIdentity(registryID:102,product:0x201d,bus:42,address:7)
    configure(c);devices=[c];store.observeUSB(devices)
    spin("re-enumeration without empty snapshot"){trace("launch")==3 && store.device != nil && !store.busy}
    let file=root.appendingPathComponent("test.nsp");try! Data([1,2,3]).write(to:file)
    store.add([file]);store.start();spin("simulated active write"){store.jobs.first?.state == .sending}
    store.pendingDeletion=DeletionPreview(storage:1,id:200,token:"1",name:"old",files:1,folders:0,bytes:3)
    devices=[];store.observeUSB([])
    precondition(store.jobs.first?.state == .interrupted && !store.transferring && !store.busy && store.pendingDeletion==nil)
    let d=USBIdentity(registryID:103,product:0x201d,bus:42,address:8)
    configure(d);devices=[d];store.observeUSB(devices)
    spin("reconnect after interrupted write"){store.device?.dev==8 && !store.busy && trace("launch")==4}
    precondition(store.jobs.first?.state == .interrupted && trace("send")==1)
    configure(d,hang:true);store.scan();spin("ping received"){trace("ping")==2}
    configure(d)
    spin("hung idle helper replaced",timeout:8){store.device?.dev==8 && !store.busy && trace("launch")==5}
    precondition(!store.logs.contains(where:{$0.contains("STALE-EVENT")}))
    store.disconnect();spin("shutdown"){store.device==nil}
    precondition(trace("launch")==5 && trace("send")==1)
    print("Connection tests passed: healthy ping preserves session, detach/replug, reused address, direct re-enumeration, stale-event isolation, interrupted-write recovery, no command replay, idle-helper timeout, clean shutdown.")
}
