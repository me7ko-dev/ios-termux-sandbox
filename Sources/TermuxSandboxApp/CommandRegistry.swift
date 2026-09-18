import ios_system
import SysInfoCommand
import SSHClientCommand
import GitCommand
import CalculatorCommand
import PythonCommand

/// Single place that wires every custom (non-ios_system-bundled) command into
/// the dispatch table. Call once, before the first command is ever run.
enum CommandRegistry {
    static func registerAll() {
        SysInfoCommand.register()
        SSHClientCommand.register()
        GitCommand.register()
        CalculatorCommand.register()
        PythonCommand.register()
        CommandsListCommand.register()
    }
}
