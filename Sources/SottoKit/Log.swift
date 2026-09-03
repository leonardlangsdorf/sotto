import Foundation
import os

/// A background agent app with no window is otherwise a black box. Watch it with:
///     log stream --predicate 'subsystem == "com.langsdorf.sotto"' --level debug
enum Log {
    static let lifecycle = Logger(subsystem: "com.langsdorf.sotto", category: "lifecycle")
    static let dictation = Logger(subsystem: "com.langsdorf.sotto", category: "dictation")
}
