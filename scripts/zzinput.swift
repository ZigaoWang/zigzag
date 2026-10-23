import AppKit
// Posts synthetic mouse events straight to Zigzag's process (window-relative points, top-left origin),
// so UI can be exercised without touching the real cursor.
// usage: zzinput <pid> <winX> <winY> <winH> move x y | click x y | drag x1 y1 x2 y2 | rclick x y | scroll dx dy x y
let a = CommandLine.arguments
let pid = pid_t(a[1])!
let wx = Double(a[2])!, wy = Double(a[3])!   // window top-left in global (top-left origin) coords
func pt(_ x: String, _ y: String) -> CGPoint { CGPoint(x: wx + Double(x)!, y: wy + Double(y)!) }
func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.postToPid(pid)
}
let cmd = a[5]
switch cmd {
case "move": post(.mouseMoved, pt(a[6], a[7]))
case "click":
    let p = pt(a[6], a[7]); post(.mouseMoved, p); usleep(30000); post(.leftMouseDown, p); usleep(40000); post(.leftMouseUp, p)
case "rclick":
    let p = pt(a[6], a[7]); post(.rightMouseDown, p, .right); usleep(40000); post(.rightMouseUp, p, .right)
case "drag":
    let p1 = pt(a[6], a[7]), p2 = pt(a[8], a[9])
    post(.mouseMoved, p1); usleep(30000); post(.leftMouseDown, p1); usleep(50000)
    for i in 1...20 {
        let t = Double(i) / 20
        post(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)); usleep(16000)
    }
    usleep(100000); post(.leftMouseUp, p2)
case "scroll":
    let p = pt(a[8], a[9])
    let dx = Int32(a[6])!, dy = Int32(a[7])!
    let phases: [Int64] = [1, 2, 2, 2, 2, 2, 2, 2, 4]
    for (i, ph) in phases.enumerated() {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i == phases.count - 1 ? 0 : dy, wheel2: i == phases.count - 1 ? 0 : dx, wheel3: 0)!
        e.location = p
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: ph)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.postToPid(pid); usleep(16000)
    }
default: break
}
