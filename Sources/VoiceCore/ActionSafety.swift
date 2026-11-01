import Foundation

public enum ActionSafety {
    public static func requiresConfirmation(_ action: Action, observation: Observation) -> Bool {
        if action.requiresConfirmation { return true }
        if action.operation == .selectOption { return true }
        guard observation.source != .visual, action.operation == .click else { return false }
        guard let control = observation.controls.first(where: { $0.id == action.target }) else { return true }
        if control.role == "link", let url = control.destination, !url.isEmpty {
            // Navigation with destructive/consequential URL semantics is never automatically safe.
            return Action(.click,label:control.label+" "+url).requiresConfirmation
        }
        // Unknown buttons are consequential until understood. Only a recognized search is exempt.
        return !["search","zoeken","zoek"].contains(CommandRouter.normalize(control.label)) ||
            !observation.controls.contains { ["searchbox","AXSearchField"].contains($0.role) && $0.canFocus }
    }
}
