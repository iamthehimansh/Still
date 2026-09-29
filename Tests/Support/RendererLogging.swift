import Foundation

func traceLog(_ message: String) {}
func extensionLog(_ message: String) { fputs("Renderer: \(message)\n", stderr) }
