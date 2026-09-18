import ios_system

/// `commands` — prints every command name ios_system currently has
/// registered. This is the actual verification tool for
/// Docs/NEXT_STEPS.md item 1: run it on-device to confirm which of the
/// bundled command dictionary's 103 entries really resolved (a dlopen
/// failure for a missing/misnamed framework fails silently per-command at
/// dispatch time, not at registration time, so a name showing up here is
/// not a 100% guarantee it runs — but a name NOT showing up here is a firm
/// "won't work").
enum CommandsListCommand {
    static func register() {
        replaceCommand("commands", "commands_main", true)
    }
}

@_cdecl("commands_main")
public func commands_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let names = commandsAsArray() as? [String] else {
        print("commands: commandsAsArray() returned nothing")
        return 1
    }
    for name in names.sorted() {
        print(name)
    }
    print("--- \(names.count) commands registered ---")
    return 0
}
