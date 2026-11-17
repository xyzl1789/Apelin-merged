import UIKit

/// 自动测速间隔的选择面板，对话面板与设置面板共用。选完即写回
/// `MeasurementSchedule`，两张表都订阅了通知刷新各自那一行。
extension UIViewController {
    @MainActor
    func presentMeasurementIntervalPicker(sourceView: UIView? = nil) {
        let sheet = UIAlertController(
            title: String(localized: "Auto Measure Interval"),
            message: nil,
            preferredStyle: .actionSheet,
        )
        for interval in MeasurementSchedule.Interval.allCases {
            let current = interval == MeasurementSchedule.interval
            let action = UIAlertAction(
                title: current ? "✓ " + interval.title : interval.title,
                style: .default,
            ) { [weak self] _ in
                MeasurementSchedule.interval = interval
                NotificationCenter.default.post(name: .measurementScheduleChanged, object: nil)
                // 开启后若已到期且确有对话开着自动切换，立刻测一轮；
                // 之后每次回前台按间隔复测，不必等用户手动点。
                MeasurementRunner.startAutomaticallyIfDue()
            }
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let sourceView {
            sheet.popoverPresentationController?.sourceView = sourceView
            sheet.popoverPresentationController?.sourceRect = CGRect(
                x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 0, height: 0,
            )
            sheet.popoverPresentationController?.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }
}

extension Notification.Name {
    static let measurementScheduleChanged = Notification.Name("wiki.qaq.apelin.measurementScheduleChanged")
}
