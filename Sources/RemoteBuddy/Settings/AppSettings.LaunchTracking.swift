import Combine
import Foundation

extension AppSettings {
    func recordLaunchAndDetectCompletedUpdate(
        currentBuild: String,
        sparkleHadLaunchedBefore: Bool
    ) -> Bool {
        let previousBuild = defaults.string(forKey: Keys.lastLaunchedBuild)
        let completedUpdate: Bool
        if
            let previousBuild,
            let previousBuildNumber = Int(previousBuild),
            let currentBuildNumber = Int(currentBuild)
        {
            completedUpdate = currentBuildNumber > previousBuildNumber
        } else {
            completedUpdate = previousBuild == nil && sparkleHadLaunchedBefore
        }

        defaults.set(currentBuild, forKey: Keys.lastLaunchedBuild)
        return completedUpdate
    }
}
