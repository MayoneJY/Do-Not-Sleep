import Foundation
import Darwin

@main
struct DoNotSleepCLI {
    @MainActor
    static var menuBarController: MenuBarAppController?

    @MainActor
    static func main() {
        do {
            try App().run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as AppError {
            fputs("\(L10n.text(.errorPrefix)): \(error.message)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("\(L10n.text(.errorPrefix)): \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
