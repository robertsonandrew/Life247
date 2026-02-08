//
//  PlaceDwellView.swift
//  Life247
//
//  Created by Andrew Robertson on 1/19/26.
//

import SwiftUI
import SwiftData
import CoreLocation

/// Dwell details for a saved Place.
///
/// Uses `PlaceVisit` as the single source of truth for dwell history.
struct PlaceDwellView: View {
    let place: Place

    @Environment(\.dismiss) private var dismiss

    @Query private var visits: [PlaceVisit]

    init(place: Place) {
        self.place = place

        let placeName = place.name
        let placeLatitude = place.latitude
        let placeLongitude = place.longitude

        _visits = Query(
            filter: #Predicate<PlaceVisit> { visit in
                visit.placeName == placeName
                && visit.placeLatitude == placeLatitude
                && visit.placeLongitude == placeLongitude
            },
            sort: [SortDescriptor(\PlaceVisit.arrivalTime, order: .reverse)]
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let active = visits.first(where: { $0.isActive })

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(activeVisit: active, now: now)

                    Divider().opacity(0.4)

                    statsGrid(now: now)

                    Divider().opacity(0.4)

                    recentVisitsSection(now: now)

                    Divider().opacity(0.4)

                    nerdySection(activeVisit: active)
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Dwell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Sections

    private func header(activeVisit: PlaceVisit?, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(placeColor(for: place.icon))
                    .frame(width: 44, height: 44)

                Image(systemName: place.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    Circle()
                        .fill(activeVisit != nil ? .green : .secondary)
                        .frame(width: 8, height: 8)

                    if let activeVisit {
                        Text("Here for \(formatDuration(activeVisit.arrivalTime...now))")
                            .foregroundStyle(.white.opacity(0.85))
                    } else if let last = visits.first {
                        Text("Last: \(last.arrivalTime.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.white.opacity(0.75))
                    } else {
                        Text("No visits yet")
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .font(.subheadline)
            }

            Spacer()
        }
    }

    private func statsGrid(now: Date) -> some View {
        let today = totalDwell(in: todayRange(now: now), now: now)
        let last7 = totalDwell(in: daysRange(7, now: now), now: now)
        let last30 = totalDwell(in: daysRange(30, now: now), now: now)

        let count7 = visitCount(in: daysRange(7, now: now))
        let avg7: TimeInterval = count7 > 0 ? last7 / Double(count7) : 0

        return VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)
                .foregroundStyle(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricCard(title: "Today", value: formatDuration(today))
                metricCard(title: "Last 7d", value: formatDuration(last7))
                metricCard(title: "Last 30d", value: formatDuration(last30))
                metricCard(title: "Avg (7d)", value: formatDuration(avg7))
            }
        }
    }

    private func recentVisitsSection(now: Date) -> some View {
        let recent = Array(visits.prefix(10))

        return VStack(alignment: .leading, spacing: 12) {
            Text("Recent visits")
                .font(.headline)
                .foregroundStyle(.white)

            if recent.isEmpty {
                Text("No visits yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(recent) { visit in
                        visitRow(visit, now: now)
                    }
                }
            }
        }
    }

    private func nerdySection(activeVisit: PlaceVisit?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nerdy")
                .font(.headline)
                .foregroundStyle(.white)

            nerdyRow(label: "Radius", value: "\(Int(place.clampedRadiusMeters)) m")
            nerdyRow(label: "Center", value: String(format: "%.5f, %.5f", place.latitude, place.longitude))

            if let activeVisit {
                nerdyRow(label: "Visit source", value: activeVisit.source)
                nerdyRow(label: "Visit coord", value: String(format: "%.5f, %.5f", activeVisit.latitude, activeVisit.longitude))
            }
        }
    }

    // MARK: - Components

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func visitRow(_ visit: PlaceVisit, now: Date) -> some View {
        let durationText = visit.isActive
            ? formatDuration(visit.arrivalTime...now)
            : formatDuration(visit.arrivalTime...(visit.departureTime ?? visit.arrivalTime))

        return HStack(spacing: 12) {
            Circle()
                .fill(visit.isActive ? Color.green : Color.white.opacity(0.2))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(visit.arrivalTime.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.white)

                if let departure = visit.departureTime {
                    Text("Left \(departure.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Text(durationText)
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func nerdyRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - Aggregation

    private func todayRange(now: Date) -> ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        return start...now
    }

    private func daysRange(_ days: Int, now: Date) -> ClosedRange<Date> {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return start...now
    }

    private func visitCount(in range: ClosedRange<Date>) -> Int {
        visits.filter { visit in
            visit.arrivalTime <= range.upperBound && (visit.departureTime ?? Date.distantFuture) >= range.lowerBound
        }.count
    }

    private func totalDwell(in range: ClosedRange<Date>, now: Date) -> TimeInterval {
        visits.reduce(0) { partial, visit in
            let start = max(visit.arrivalTime, range.lowerBound)
            let end = min(visit.departureTime ?? now, range.upperBound)
            guard end > start else { return partial }
            return partial + end.timeIntervalSince(start)
        }
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let hours = s / 3600
        let minutes = (s % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatDuration(_ interval: ClosedRange<Date>) -> String {
        formatDuration(interval.upperBound.timeIntervalSince(interval.lowerBound))
    }
}
