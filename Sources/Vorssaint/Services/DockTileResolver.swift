// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

/// Turns a Dock tile into the process it stands for.
///
/// Matching a tile's AXURL against `bundleURL` is enough for the ordinary app,
/// which owns exactly one process. It collapses apps that run as several
/// separate processes: each instance gets its own tile, yet every tile reports
/// the same bundle URL, so clicking any of them acted on whichever instance the
/// workspace happened to list first and the other instances were unreachable
/// from the Dock.
///
/// Both the Dock click tap and the Dock preview hit test resolve through here,
/// so a preview panel opened over one tile and a click on that tile always mean
/// the same process.
enum DockTileResolver {
    /// The instance behind the tile at `index` of `items`, the Dock's own item
    /// list the caller is already walking.
    static func application(forTileAt index: Int,
                            in items: [AXUIElement],
                            bundlePath: String) -> NSRunningApplication? {
        let instances = runningInstances(bundlePath: bundlePath)
        // The case virtually every click takes, and the one that runs inside the
        // click tap's Accessibility budget: a single instance needs no ordinal,
        // so it costs no extra AX round trip at all.
        guard instances.count > 1 else { return instances.first }
        return instance(from: instances,
                        tileOrdinal: tileOrdinal(at: index, in: items, bundlePath: bundlePath))
    }

    /// The instance behind a tile a caller found by AX hit testing, which leaves
    /// it holding an element rather than a place in a list. Answers nil when the
    /// element names no bundle, or no process of that bundle is running, so the
    /// caller keeps whatever fallback it had.
    static func application(forTile tile: AXUIElement) -> NSRunningApplication? {
        guard let url = urlAttribute(tile) else { return nil }
        let bundlePath = url.standardizedFileURL.path
        let instances = runningInstances(bundlePath: bundlePath)
        guard instances.count > 1 else { return instances.first }
        // Reached only once the bundle turns out to have several instances, so
        // the extra AXParent and AXChildren reads stay off the ordinary path.
        guard let parent = elementAttribute(tile, kAXParentAttribute as String),
              stringAttribute(parent, kAXRoleAttribute as String) == "AXList",
              let items = elementArray(parent, kAXChildrenAttribute as String),
              // AXUIElement carries no Swift equality; CFEqual is how this
              // codebase already compares accessibility elements.
              let index = items.firstIndex(where: { CFEqual($0, tile) })
        else {
            // Nothing to count against: the oldest instance is where the Dock's
            // own first tile points, and where the bundle match landed before.
            return instance(from: instances, tileOrdinal: 0)
        }
        return instance(from: instances,
                        tileOrdinal: tileOrdinal(at: index, in: items, bundlePath: bundlePath))
    }

    /// Every live, regular process running this exact bundle. Only regular apps
    /// get a tile, so this filter matches the tile set the ordinal counts.
    private static func runningInstances(bundlePath: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.bundleURL?.standardizedFileURL.path == bundlePath
        }
    }

    /// How many tiles for the same bundle sit ahead of this one. Reads AXURL for
    /// the earlier items only, and from the Dock rather than the clicked app:
    /// the caller's own walk already reads attributes from that same process, so
    /// this adds to an existing cost rather than a new one. Tiles whose frame the
    /// caller could not read still hold their slot, which is what keeps the count
    /// aligned with the tiles the Dock actually shows.
    private static func tileOrdinal(at index: Int,
                                    in items: [AXUIElement],
                                    bundlePath: String) -> Int {
        items.prefix(index).reduce(into: 0) { count, item in
            if urlAttribute(item)?.standardizedFileURL.path == bundlePath { count += 1 }
        }
    }

    private static func instance(from instances: [NSRunningApplication],
                                 tileOrdinal: Int) -> NSRunningApplication? {
        let described = instances.map {
            DockAppInstance(pid: $0.processIdentifier,
                            launchTime: $0.launchDate?.timeIntervalSinceReferenceDate)
        }
        guard let slot = DockClickSupport.instanceIndex(tileOrdinal: tileOrdinal,
                                                        instances: described) else { return nil }
        return instances[slot]
    }

    // MARK: - Accessibility reads

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func elementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement]
        else { return nil }
        return array
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func urlAttribute(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFURLGetTypeID()
        else { return nil }
        return (value as! CFURL) as URL
    }
}
