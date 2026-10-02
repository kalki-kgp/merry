import Foundation

/// Every tool Merry has, in the order the planner is shown them.
public func allTools() -> [ToolDefinition] {
    documentTools + brainTools + fileTools + shellTools + userTools + desktopTools + browserTools + macTools + yourBrowserTools + [rememberTool]
}
