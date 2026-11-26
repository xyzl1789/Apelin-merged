import AppKit
import SwiftUI

// 生产 ChatActivityDetailLayout 由 Python 测试提取并前置，不另写测量实现。
// 在同一个 SwiftUI 宿主里连续改变详情数量和行高，检查真实拟合高度而非模拟值。
@available(macOS 13.0, *)
private final class DetailModel: ObservableObject {
    @Published var count = 3
    @Published var rowHeight: CGFloat = 18
    var titleTop: CGFloat?
}

private struct TitleTopKey: PreferenceKey {
    static var defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@available(macOS 13.0, *)
private struct DetailFixture: View {
    @ObservedObject var model: DetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Apelin")
                .font(.caption.bold())
                .lineLimit(1)
                .fixedSize()
                .frame(height: 20)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: TitleTopKey.self,
                                               value: geometry.frame(in: .named("card")).minY)
                    }
                }
                .layoutPriority(2)
            if model.count > 0 {
                ChatActivityDetailLayout {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<model.count, id: \.self) { _ in
                            Color.green.frame(height: model.rowHeight)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .id("\(model.count)-\(model.rowHeight)")
                .clipped()
                .layoutPriority(-1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .id("\(model.count)-\(model.rowHeight)")
        .coordinateSpace(name: "card")
        .onPreferenceChange(TitleTopKey.self) { model.titleTop = $0 }
        .frame(width: 240)
    }
}

if #available(macOS 13.0, *) {
    _ = NSApplication.shared
    let model = DetailModel()
    let host = NSHostingView(rootView: DetailFixture(model: model))
    host.setFrameSize(NSSize(width: 240, height: 140))
    // 同一宿主始终保留较大的 frame，模拟系统继续提出旧高度；不能通过重设宿主高度掩盖问题。
    for (count, rowHeight): (Int, CGFloat) in [
        (3, 18), (2, 18), (1, 18), (0, 18),
        (3, 36), (2, 36), (2, 18), (1, 18), (0, 18), (3, 18),
    ] {
        model.count = count
        model.rowHeight = rowHeight
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let detail = count == 0 ? 0 : min(CGFloat(count) * rowHeight + CGFloat(count - 1) * 3, 76)
        let expected: CGFloat = 20 + (count == 0 ? 0 : 4 + detail)
        precondition(abs(size.height - expected) < 1,
                     "详情数量 \(count)、行高 \(rowHeight)：实际 \(size.height)，预期 \(expected)")
        precondition(model.titleTop.map { abs($0) < 1 } == true,
                     "详情变化后标题必须仍在卡片顶部")
        precondition(abs(host.frame.height - 140) < 1, "宿主必须持续保留旧的大高度提议")
    }
    print("通过：同一 SwiftUI 宿主三条→两条→一条→零条、行高缩短及再次增大")
} else {
    fatalError("布局回归需要 macOS 13 或更新版本")
}
