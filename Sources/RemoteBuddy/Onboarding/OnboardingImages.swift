import AppKit
import Combine
import CoreBluetooth
import SwiftUI

enum OnboardingImageCache {
    private static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()
    static func image(at url: URL) -> NSImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let pixels = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh }
        images.setObject(image, forKey: url as NSURL, cost: max(1, pixels) * 4)
        return image
    }
}
