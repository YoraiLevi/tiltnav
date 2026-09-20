import Cocoa
setvbuf(stdout, nil, _IOLBF, 0)
// Read-only tap: prints every discriminator macOS attaches to a horizontal scroll event.
let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
let cb: CGEventTapCallBack = { _, type, e, _ in
    guard type == .scrollWheel else { return Unmanaged.passUnretained(e) }
    let h = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    let v = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    if h == 0 && v == 0 { return Unmanaged.passUnretained(e) }
    let cont  = e.getIntegerValueField(.scrollWheelEventIsContinuous)
    let sph   = e.getIntegerValueField(.scrollWheelEventScrollPhase)
    let mph   = e.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let ptH   = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    let fixH  = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
    let pid   = e.getIntegerValueField(.eventSourceUnixProcessID)
    print(String(format: "h=%4d v=%4d cont=%d scrollPhase=%d momentum=%d pointH=%5d fixedH=%+7.2f srcpid=%d",
                 h, v, cont, sph, mph, ptH, fixH, pid))
    return Unmanaged.passUnretained(e)
}
guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                options: .listenOnly, eventsOfInterest: mask,
                                callback: cb, userInfo: nil) else {
    print("NO TAP — Accessibility not granted to this binary"); exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
CGEvent.tapEnable(tap: t, enable: true)
print("listening — tilt the trackball, then swipe the trackpad. ctrl-c to stop.")
CFRunLoopRun()
