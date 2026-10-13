import SwiftUI

extension View {
    /// Shows `panel` as the Recap panel beside this view: a fixed-width trailing column on macOS, an inspector on iOS
    /// (a column on iPad, a sheet on iPhone).
    ///
    /// macOS doesn't use `.inspector` because the panel sits in a `NavigationSplitView` detail column there. On
    /// macOS 27 an inspector in that column sent AppKit into an endless constraint-update loop, which aborts the app,
    /// whenever the window was too narrow for the columns' ideal widths (below about 1050 pt).
    func recapPanel<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder panel: () -> Panel) -> some View {
        #if os(macOS)
        HStack(spacing: 0) {
            self
            if isPresented.wrappedValue {
                Divider()
                panel()
                    .frame(width: 320)
            }
        }
        #else
        inspector(isPresented: isPresented) {
            panel()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
                .presentationDragIndicator(.visible)
        }
        #endif
    }
}
