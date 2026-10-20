import Foundation

enum VisualSignals {

    static let analysisVersion = 2

    static let actionLabels: Set<String> = [
        "sport", "dancing", "breakdancing", "ballet", "ballet_dancer", "bellydance",
        "concert", "performance", "celebration", "crowd", "fireworks", "firecracker",
        "nightclub", "carnival", "skateboarding", "skiing", "snowboarding", "surfing",
        "swimming", "cycling", "skydiving", "jetski", "waterpolo", "watersport",
        "winter_sport", "motorsport", "basketball", "football", "volleyball", "baseball",
        "windsurfing", "disco_ball",
    ]

    static let emotionalLabels: Set<String> = [
        "celebration", "wedding", "wedding_dress", "wedding_cake", "birthday_cake",
        "graduation", "baby", "child", "teen", "dog", "cat", "fireworks", "concert",
        "sunset_sunrise", "carnival", "crowd", "balloon",
    ]

    static let sceneryLabels: Set<String> = [
        "sky", "blue_sky", "mountain", "ocean", "beach", "lake", "waterfall", "cityscape",
        "skyscraper", "desert", "forest", "snow", "night_sky", "sunset_sunrise",
        "water_body", "road", "dirt_road", "waterways",
    ]

    static let detailLabels: Set<String> = [
        "food", "cake", "cake_regular", "cupcake", "flower", "flower_arrangement",
        "sunflower", "drink", "seafood", "textile", "musical_instrument",
    ]

    static let utilityLabels: Set<String> = [
        "screenshot", "document", "receipt", "whiteboard", "credit_card", "passport",
        "gift_card",
    ]

    static func displayLabels(_ identifiers: [String], limit: Int = 10) -> [String] {
        var seen = Set<String>()
        return identifiers
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    static func isUtility(identifiers: [String], aestheticsSaysUtility: Bool) -> Bool {
        aestheticsSaysUtility || identifiers.prefix(3).contains { utilityLabels.contains($0) }
    }

    static func qualityScore(aesthetic: Float?, isUtility: Bool,
                             bestFaceQuality: Float?, isFavorite: Bool) -> Float {
        if isUtility { return 0.1 }
        var q = aesthetic.map { 0.5 + 0.6 * $0 } ?? 0.6
        if let face = bestFaceQuality {
            q = q * 0.75 + face * 0.25
        }
        if isFavorite { q += 0.08 }
        return clamp(q)
    }

    static func emotionScore(faceCount: Int, identifiers: [String], isFavorite: Bool) -> Float {
        var e: Float = 0.35
        if faceCount > 0 { e += 0.2 }
        if faceCount >= 3 { e += 0.1 }
        let emotionalHits = identifiers.filter { emotionalLabels.contains($0) }.count
        e += min(0.25, Float(emotionalHits) * 0.12)
        if isFavorite { e += 0.15 }
        return clamp(e)
    }

    static func photoMotionEnergy(faceCount: Int, identifiers: [String]) -> Float {
        let actionHits = identifiers.filter { actionLabels.contains($0) }.count
        var m: Float = 0.25 + min(0.45, Float(actionHits) * 0.2)
        if faceCount >= 3 { m += 0.05 }
        return clamp(m)
    }

    static func overallScore(quality: Float, emotion: Float, novelty: Float) -> Float {
        quality * 0.45 + emotion * 0.35 + novelty * 0.20
    }

    static func shotType(faceCount: Int, largestFaceArea: Double, identifiers: [String],
                         isVideo: Bool, motionEnergy: Float?) -> ShotType {
        if faceCount > 0 && largestFaceArea >= 0.08 { return .closeUp }
        if isVideo, (motionEnergy ?? 0) > 0.6 { return .motion }
        if faceCount >= 3 { return .group }
        if faceCount > 0 { return .medium }
        let top = identifiers.prefix(5)
        if top.contains(where: { sceneryLabels.contains($0) }) { return .wide }
        if top.contains(where: { detailLabels.contains($0) }) { return .detail }
        return .medium
    }

    static func noveltyScores(_ embeddings: [[Float]?]) -> [Float?] {
        embeddings.indices.map { i in
            guard let a = embeddings[i] else { return nil }
            var maxSim: Float = -1
            for j in embeddings.indices where j != i {
                guard let b = embeddings[j], let sim = cosine(a, b) else { continue }
                maxSim = max(maxSim, sim)
            }
            guard maxSim > -1 else { return 0.7 }
            return clamp((1 - maxSim) / 0.6)
        }
    }

    static func eventLabels(dates: [Date?], locations: [AssetLocation?],
                            gap: TimeInterval = 3 * 3600,
                            maxDistanceKm: Double = 30) -> [String?] {
        let order = dates.indices
            .filter { dates[$0] != nil }
            .sorted { dates[$0]! < dates[$1]! }
        guard !order.isEmpty else { return dates.map { _ in nil } }

        var eventOf = [Int: Int]()
        var eventStarts = [Date]()
        var prev: Int? = nil
        for i in order {
            let date = dates[i]!
            var newEvent = prev == nil
            if let p = prev {
                if date.timeIntervalSince(dates[p]!) > gap { newEvent = true }
                if let a = locations[p], let b = locations[i],
                   distanceKm(a, b) > maxDistanceKm { newEvent = true }
            }
            if newEvent { eventStarts.append(date) }
            eventOf[i] = eventStarts.count - 1
            prev = i
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var perDay = [String: Int]()
        let names: [String] = eventStarts.map { start in
            let day = formatter.string(from: start)
            perDay[day, default: 0] += 1
            let n = perDay[day]!
            return n == 1 ? day : "\(day) · \(n)"
        }
        return dates.indices.map { i in eventOf[i].map { names[$0] } }
    }

    static func distanceKm(_ a: AssetLocation, _ b: AssetLocation) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for k in a.indices {
            dot += a[k] * b[k]
            na += a[k] * a[k]
            nb += b[k] * b[k]
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func clamp(_ v: Float) -> Float { min(1, max(0, v)) }
}
