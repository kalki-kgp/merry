import Foundation

public let WORKFLOWS: [Workflow] = [memoryWorkflow] + assistWorkflows + [organizeWorkflow, findWorkflow, renameWorkflow, commandWorkflow]

public struct WorkflowMatch: Sendable {
    public var workflow: Workflow
    public var confidence: Double
    public var reason: String
}

/// Picks a workflow for a request, or returns nil to hand off to the planner.
///
/// Local plausibility checks narrow the field first, so a request that clearly
/// matches exactly one workflow costs nothing to route. Jev is asked only when
/// more than one is plausible, and it chooses between the shortlist, including
/// an explicit "none of these" option, so it can decline.
public func routeToWorkflow(_ request: String, _ droppedPaths: [String], _ ctx: WorkflowContext, route: String, workflows: [Workflow] = WORKFLOWS) async -> WorkflowMatch? {
    // Keyword matching alone may not claim a request. Each workflow declares
    // the routes it belongs to, and the route (local rules, or Jev when they
    // are unsure) decides what kind of work this is. That gate is why "open
    // youtube and search for a good video" no longer searches the Downloads
    // folder for a video file.
    let effective = route == "unclear" && !droppedPaths.isEmpty ? "files" : route
    let plausible = workflows.filter { $0.routes.contains(effective) && $0.plausible(request, droppedPaths) }
    if plausible.isEmpty {
        ctx.log(.info, "nothing matches a \"\(effective)\" request; handing to the planner")
        return nil
    }
    if plausible.count == 1 {
        return WorkflowMatch(workflow: plausible[0], confidence: 0.8, reason: "the request matches one known workflow")
    }

    var criteria = [("none", "None of these fit; this needs general-purpose planning.")]
    for w in plausible { criteria.append((w.id, w.description)) }

    let answers = await ctx.ask(
        "route_workflow",
        ["userRequest": .string(request), "filesDropped": JSON(droppedPaths.count)],
        [("workflow", .choice("Which of these jobs is the user asking for?", criteria))]
    )
    guard let answers else {
        // No Jev: take the first plausible match rather than stalling.
        return WorkflowMatch(workflow: plausible[0], confidence: 0.5, reason: "first plausible match (Jev unavailable)")
    }
    // Defend against an unexpected answer shape rather than throwing inside the
    // router: falling back to the planner is always a safe outcome.
    guard let pick = answers["workflow"], let choice = pick.choice else {
        ctx.log(.warn, "Jev returned no usable workflow choice; handing off to the planner")
        return nil
    }
    if choice == "none" {
        ctx.log(.info, "Jev declined all workflows; handing off to the planner")
        return nil
    }
    guard let workflow = plausible.first(where: { $0.id == choice }) else { return nil }
    let confidence = pick.confidence ?? 0
    return WorkflowMatch(workflow: workflow, confidence: confidence, reason: "Jev chose \(workflow.id) (\((confidence * 100).toFixed(0))% confident)")
}
