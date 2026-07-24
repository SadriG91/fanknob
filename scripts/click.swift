import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    print("usage: click <x> <y>"); exit(1)
}
let pt = CGPoint(x: x, y: y)
// Move, press, release — a real click through the window server.
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                   mouseCursorPosition: pt, mouseButton: .left)!
move.post(tap: .cghidEventTap)
usleep(50_000)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                   mouseCursorPosition: pt, mouseButton: .left)!
down.post(tap: .cghidEventTap)
usleep(60_000)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                 mouseCursorPosition: pt, mouseButton: .left)!
up.post(tap: .cghidEventTap)
