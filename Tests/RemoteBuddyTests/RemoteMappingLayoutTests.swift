import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RemoteBuddy

@Suite("Remote mapping illustration alignment")
struct RemoteMappingLayoutTests {
    @Test func xiaomiConnectorsMeetIllustratedButtonCenters() throws {
        // Pixel centers in the 508 × 1030 artwork (the PNG is rendered at 2×).
        let centers: [(RemoteButton, CGPoint)] = [
            (.power, CGPoint(x: 196.09, y: 101.97)),
            (.up, CGPoint(x: 255.02, y: 184.37)),
            (.left, CGPoint(x: 183.90, y: 253.38)),
            (.back, CGPoint(x: 206.25, y: 400.67)),
            (.home, CGPoint(x: 206.25, y: 493.37)),
            (.menu, CGPoint(x: 206.25, y: 586.07)),
            (.right, CGPoint(x: 324.10, y: 253.38)),
            (.ok, CGPoint(x: 255.02, y: 253.38)),
            (.down, CGPoint(x: 255.02, y: 326.51)),
            (.volumeUp, CGPoint(x: 306.83, y: 401.70)),
            (.volumeDown, CGPoint(x: 306.83, y: 494.40)),
            (.tv, CGPoint(x: 306.83, y: 586.07)),
        ]
        #expect(RemoteMappingLayout.buttonPlacements.count == centers.count)
        for width: CGFloat in [860, 1000, 1400] {
            let origin = CGPoint(
                x: (width - RemoteMappingLayout.remoteSize.width) / 2,
                y: (RemoteMappingLayout.canvasHeight - RemoteMappingLayout.remoteSize.height) / 2
            )
            let scale = RemoteMappingLayout.remoteSize.width / 508
            for (button, center) in centers {
                let placement = try #require(RemoteMappingLayout.buttonPlacements.first { $0.button == button })
                let point = RemoteMappingLayout.remotePoint(for: placement.anchor, canvasWidth: width)
                #expect(abs(point.x - (origin.x + center.x * scale)) < 0.01)
                #expect(abs(point.y - (origin.y + center.y * scale)) < 0.01)
            }
            let voice = RemoteMappingLayout.remotePoint(for: RemoteMappingLayout.voiceAnchor, canvasWidth: width)
            #expect(abs(voice.x - (origin.x + 320.04 * scale)) < 0.01)
            #expect(abs(voice.y - (origin.y + 101.97 * scale)) < 0.01)
        }
    }

    @Test func xiaomiRenderedAspectRatioMatchesTheActualArtwork() throws {
        let url = try #require(RemoteBuddyResourceBundle.mainOrDevelopment.url(
            forResource: "BuddyRemoteIllustration", withExtension: "png"))
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let imageRatio = Double(bitmap.pixelsHigh) / Double(bitmap.pixelsWide)
        let layoutRatio = RemoteMappingLayout.remoteSize.height / RemoteMappingLayout.remoteSize.width
        #expect(abs(imageRatio - layoutRatio) < 0.0001)
        #expect(RemoteMappingLayout.remoteSize.height < RemoteMappingLayout.canvasHeight)
    }

    @Test func chromecastAnchorsRemainNormalizedToItsOwnIllustration() {
        for anchor in G9N9NMappingLayout.placements.map(\.anchor) + [G9N9NMappingLayout.voiceAnchor] {
            let point = RemoteMappingLayout.remotePoint(
                for: anchor,
                canvasWidth: 1000,
                remoteSize: G9N9NMappingLayout.remoteSize,
                canvasHeight: G9N9NMappingLayout.canvasHeight
            )
            #expect(abs(point.x - (420 + anchor.x * 160)) < 0.01)
            #expect(abs(point.y - (85 + anchor.y * 480)) < 0.01)
        }
    }

    @Test func t1RenderedAspectRatioAndAnchorsMatchFrontIllustrationWithoutOverlap() throws {
        let url = try #require(RemoteBuddyResourceBundle.mainOrDevelopment.url(
            forResource: "T1RemoteIllustration", withExtension: "png"))
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let imageRatio = Double(bitmap.pixelsHigh) / Double(bitmap.pixelsWide)
        let layoutRatio = T1RemoteMappingLayout.remoteSize.height / T1RemoteMappingLayout.remoteSize.width
        #expect(abs(imageRatio - layoutRatio) < 0.0001)
        #expect(T1RemoteMappingLayout.remoteSize.height < T1RemoteMappingLayout.canvasHeight)
        #expect(T1RemoteMappingLayout.placements.count == 12)
        #expect(Set(T1RemoteMappingLayout.placements.map(\.button)).count == 12)

        for anchor in T1RemoteMappingLayout.placements.map(\.anchor) + [T1RemoteMappingLayout.voiceAnchor] {
            let point = RemoteMappingLayout.remotePoint(
                for: anchor,
                canvasWidth: 1000,
                remoteSize: T1RemoteMappingLayout.remoteSize,
                canvasHeight: T1RemoteMappingLayout.canvasHeight
            )
            let originX = (1000 - T1RemoteMappingLayout.remoteSize.width) / 2
            let originY = (T1RemoteMappingLayout.canvasHeight - T1RemoteMappingLayout.remoteSize.height) / 2
            #expect(abs(point.x - (originX + anchor.x * T1RemoteMappingLayout.remoteSize.width)) < 0.01)
            #expect(abs(point.y - (originY + anchor.y * T1RemoteMappingLayout.remoteSize.height)) < 0.01)
        }

        let leftYs = T1RemoteMappingLayout.placements.filter { $0.side == .left }.map(\.targetY).sorted()
        for pair in zip(leftYs, leftYs.dropFirst()) {
            #expect((pair.1 - pair.0) * T1RemoteMappingLayout.canvasHeight > 72)
        }
        let rightYs = (T1RemoteMappingLayout.placements.filter { $0.side == .right }.map(\.targetY)
            + [T1RemoteMappingLayout.voiceTargetY]).sorted()
        for pair in zip(rightYs, rightYs.dropFirst()) {
            #expect((pair.1 - pair.0) * T1RemoteMappingLayout.canvasHeight > 72)
        }
    }
}
