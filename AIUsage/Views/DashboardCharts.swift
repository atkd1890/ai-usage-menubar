import SwiftUI
import Charts

nonisolated enum AnalyticsDisplay {
    static func compact(_ value: Double) -> String {
        if value >= 1e9 { return String(format: "%.2fB", value / 1e9) }
        if value >= 1e6 { return String(format: "%.1fM", value / 1e6) }
        if value >= 1e3 { return String(format: "%.1fK", value / 1e3) }
        return String(format: "%.0f", value)
    }
    static func number(_ value: Double, unit: AnalyticsUnit) -> String {
        unit == .tokens ? compact(value) : value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
    }
    static func model(_ name: String) -> String {
        switch name {
        case "gpt-6.1-sol": "GPT-6.1 Sol"
        case "gpt-6-astra": "GPT-6 Astra"
        case "claude-opus-5-5": "Claude Opus 5.5"
        case "claude-sonnet-5-5": "Claude Sonnet 5.5"
        default: name
        }
    }
}

private struct AnalyticsDayTooltip: View {
    let date: Date
    let day: AnalyticsDay
    let unit: AnalyticsUnit
    let hits: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())).font(.caption.weight(.semibold))
            HStack { Text("Tokens"); Spacer(); Text(AnalyticsDisplay.compact(day.amount.tokens)).monospacedDigit() }
            HStack { Text("API value"); Spacer(); Text(day.amount.pricedRecords > 0 ? day.amount.value.formatted(.currency(code: "USD")) : "—").monospacedDigit() }
            if !day.series.isEmpty { Divider() }
            ForEach(day.series.sorted { $0.value.number(unit) > $1.value.number(unit) }.prefix(6), id: \.key) { series, amount in
                HStack {
                    ProviderIcon(provider: series.lowercased().contains("claude") ? .claude : .codex, size: 13)
                        .foregroundStyle(series.lowercased().contains("claude") ? Color.orange : Color.cyan)
                    Text(AnalyticsDisplay.model(series)).lineLimit(1)
                    Spacer()
                    Text(unit == .value && amount.pricedRecords == 0 ? "—" : AnalyticsDisplay.number(amount.number(unit), unit: unit)).monospacedDigit()
                }
            }
            if day.amount.records == 0 { Text("No local usage recorded.").foregroundStyle(.secondary) }
            if day.amount.unpriced > 0 { Text("API value excludes unpriced models.").foregroundStyle(.secondary) }
            if hits > 0 { Label("\(hits) limit \(hits == 1 ? "hit" : "hits")", systemImage: "circle.fill").foregroundStyle(.red) }
        }
        .font(.caption2)
        .padding(12)
        .frame(width: 240)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.2), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
    }
}

struct DashboardUsageChart: View {
    let data: DashboardProjection
    let unit: AnalyticsUnit
    let start: Date
    let end: Date
    let days: Int
    let colors: [Color]
    @State private var hovered: Date?
    private var maximum: Double { max(1, data.periodDays.values.map { $0.amount.number(unit) }.max() ?? 0) }
    private var chartTop: Double { maximum * 1.2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PER DAY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                ForEach(Array(data.series.enumerated()), id: \.element) { index, series in
                    RoundedRectangle(cornerRadius: 2).fill(colors.indices.contains(index) ? colors[index] : .cyan).frame(width: 7, height: 7)
                    Text(AnalyticsDisplay.model(series)).font(.caption).foregroundStyle(.secondary)
                }
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("Limit hit").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(data.bars) { bar in
                    if unit == .tokens || bar.amount.pricedRecords > 0 {
                        BarMark(x: .value("Day", bar.date, unit: .day), y: .value(unit.rawValue, bar.amount.number(unit)))
                            .foregroundStyle(by: .value("Usage", bar.series))
                    }
                }
                if data.total.number(unit) > 0 {
                    RuleMark(y: .value("Average", data.total.number(unit) / Double(days)))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(.secondary)
                        .annotation(position: .leading) {
                            Text("avg \(AnalyticsDisplay.number(data.total.number(unit) / Double(days), unit: unit))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                ForEach(data.hitsByDay.keys.sorted(), id: \.self) { date in
                    ForEach(0..<min(5, data.hitsByDay[date] ?? 0), id: \.self) { index in
                        PointMark(x: .value("Day", date, unit: .day),
                                  y: .value("Limit hit", (data.periodDays[date]?.amount.number(unit) ?? 0) + maximum * (0.025 + Double(index) * 0.035)))
                            .foregroundStyle(.red).symbolSize(24)
                    }
                }
                if let hovered {
                    RuleMark(x: .value("Selected day", hovered.addingTimeInterval(43200)))
                        .foregroundStyle(.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: data.series, range: colors)
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...chartTop)
            .chartYAxis { AxisMarks(position: .leading) { value in
                AxisGridLine(); AxisValueLabel { if let number = value.as(Double.self) { Text(AnalyticsDisplay.number(number, unit: unit)) } }
            } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard let anchor = proxy.plotFrame else { hovered = nil; return }
                                let frame = geometry[anchor]
                                guard frame.contains(point), let date = proxy.value(atX: point.x - frame.minX, as: Date.self) else { hovered = nil; return }
                                let day = Calendar.current.startOfDay(for: date)
                                if hovered != day { hovered = day }
                            case .ended: hovered = nil
                            }
                        }
                    if let hovered {
                        AnalyticsDayTooltip(date: hovered, day: data.periodDays[hovered] ?? AnalyticsDay(), unit: unit, hits: data.hitsByDay[hovered] ?? 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.top, 28).padding(.trailing, 8)
                    }
                }
            }
            .frame(height: 290)
        }
    }
}

struct DashboardHeatmap: View {
    let data: DashboardProjection
    let unit: AnalyticsUnit
    let today: Date
    let weeks: [[Date]]
    @State private var hovered: Date?
    @State private var hoverX: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("LAST 53 WEEKS").font(.caption.weight(.semibold)); Spacer()
                Text("Less").font(.caption2)
                ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.08 + Double(index) * 0.19)).frame(width: 10, height: 10) }
                Text("More").font(.caption2)
            }.foregroundStyle(.secondary)
            GeometryReader { geometry in
                let cell = max(1, (geometry.size.width - 30 - 3 * 52) / 53)
                let maximum = unit == .tokens ? data.maximumTokens : data.maximumValue
                Canvas(rendersAsynchronously: true) { context, _ in
                    for day in 0..<7 {
                        let label = ["Mon", "", "Wed", "", "Fri", "", ""][day]
                        context.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: 0, y: 21 + CGFloat(day) * (cell + 3) + cell / 2), anchor: .leading)
                    }
                    for week in weeks.indices {
                        let x = 30 + CGFloat(week) * (cell + 3)
                        let first = weeks[week][0]
                        let month = Calendar.current.component(.month, from: first)
                        if week == 0 || month != Calendar.current.component(.month, from: weeks[week - 1][0]) {
                            context.draw(Text(first.formatted(.dateTime.month(.abbreviated))).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x, y: 8), anchor: .leading)
                        }
                        for day in 0..<7 {
                            let date = weeks[week][day]
                            let value = data.days[date]?.amount.number(unit) ?? 0
                            let rect = CGRect(x: x, y: 21 + CGFloat(day) * (cell + 3), width: cell, height: cell)
                            let opacity = date > today ? 0.025 : value > 0 ? 0.18 + 0.8 * sqrt(value / maximum) : 0.08
                            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.primary.opacity(opacity)))
                            if hovered == date { context.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 2), with: .color(.cyan), lineWidth: 1.5) }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let column = Int(floor((point.x - 30) / (cell + 3)))
                        let row = Int(floor((point.y - 21) / (cell + 3)))
                        guard point.x >= 30, point.y >= 21, weeks.indices.contains(column), (0..<7).contains(row), weeks[column][row] <= today else { hovered = nil; return }
                        let date = weeks[column][row]
                        if hovered != date { hovered = date; hoverX = 30 + CGFloat(column) * (cell + 3) }
                    case .ended: hovered = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hovered {
                        let day = data.days[hovered] ?? AnalyticsDay()
                        AnalyticsDayTooltip(date: hovered, day: day, unit: unit, hits: data.hitsByDay[hovered] ?? 0)
                            .offset(x: min(max(0, hoverX - 120), max(0, geometry.size.width - 240)),
                                    y: -CGFloat(100 + min(6, day.series.count) * 20))
                    }
                }
            }.aspectRatio(5.6, contentMode: .fit)
            .accessibilityLabel("53 weeks of daily usage. Hover a day for details.")
        }.zIndex(2)
    }
}
