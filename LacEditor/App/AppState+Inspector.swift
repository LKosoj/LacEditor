import Foundation

extension AppState {
    /// Писательская вкладка — привязанная к проекту рукописи.
    var inspectorIsWriterTab: Bool { writerSession != nil }
    var effectiveInspectorSegment: InspectorSegment { InspectorSegment.resolve(inspectorSegment, isWriter: inspectorIsWriterTab) }
}
