import SwiftUI
import WidgetKit

@main
struct BojiClubWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayTrainingWidget()
        TrainingLiveActivityWidget()
    }
}
